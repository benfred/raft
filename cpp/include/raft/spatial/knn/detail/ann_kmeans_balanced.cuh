/*
 * Copyright (c) 2022, NVIDIA CORPORATION.
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *     http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

#pragma once

#include "ann_utils.cuh"

#include <thrust/gather.h>
#include <thrust/transform.h>

#include <raft/cluster/detail/kmeans_common.cuh>
#include <raft/common/nvtx.hpp>
#include <raft/core/cudart_utils.hpp>
#include <raft/core/logger.hpp>
#include <raft/distance/distance.cuh>
#include <raft/distance/distance_types.hpp>
#include <raft/distance/fused_l2_nn.cuh>
#include <raft/linalg/add.cuh>
#include <raft/linalg/gemm.cuh>
#include <raft/linalg/matrix_vector_op.cuh>
#include <raft/linalg/norm.cuh>
#include <raft/linalg/unary_op.cuh>
#include <raft/matrix/matrix.cuh>
#include <raft/util/cuda_utils.cuh>

#include <rmm/cuda_stream_view.hpp>
#include <rmm/device_scalar.hpp>
#include <rmm/device_vector.hpp>
#include <rmm/mr/device/device_memory_resource.hpp>
#include <rmm/mr/device/managed_memory_resource.hpp>
#include <rmm/mr/device/per_device_resource.hpp>

namespace raft::spatial::knn::detail::kmeans {

constexpr static inline const float kAdjustCentersWeight = 7.0f;

/**
 * @brief Predict labels for the dataset; floats only.
 *
 * NB: no minibatch splitting is done here, it may require large amount of temporary memory (n_rows
 * * n_cluster * sizeof(float)).
 *
 * @tparam IdxT   index type
 * @tparam LabelT label type
 *
 * @param handle
 * @param[in] centers a pointer to the row-major matrix of cluster centers [n_clusters, dim]
 * @param n_clusters number of clusters/centers
 * @param dim dimensionality of the data
 * @param[in] dataset a pointer to the data [n_rows, dim]
 * @param[in] dataset_norm pointer to the precomputed norm (for L2 metrics only) [n_rows]
 * @param n_rows number samples in the `dataset`
 * @param[out] labels output predictions [n_rows]
 * @param metric
 * @param stream
 * @param mr (optional) memory resource to use for temporary allocations
 */
template <typename IdxT, typename LabelT>
inline void predict_float_core(const handle_t& handle,
                               const float* centers,
                               uint32_t n_clusters,
                               uint32_t dim,
                               const float* dataset,
                               const float* dataset_norm,
                               IdxT n_rows,
                               LabelT* labels,
                               raft::distance::DistanceType metric,
                               rmm::cuda_stream_view stream,
                               rmm::mr::device_memory_resource* mr)
{
  switch (metric) {
    case raft::distance::DistanceType::L2Expanded:
    case raft::distance::DistanceType::L2SqrtExpanded: {
      auto workspace = raft::make_device_mdarray<char, IdxT>(
        handle, mr, make_extents<IdxT>((sizeof(int)) * n_rows));

      auto minClusterAndDistance = raft::make_device_mdarray<raft::KeyValuePair<IdxT, float>, IdxT>(
        handle, mr, make_extents<IdxT>(n_rows));
      raft::KeyValuePair<IdxT, float> initial_value(0, std::numeric_limits<float>::max());
      thrust::fill(handle.get_thrust_policy(),
                   minClusterAndDistance.data_handle(),
                   minClusterAndDistance.data_handle() + minClusterAndDistance.size(),
                   initial_value);

      auto centroidsNorm =
        raft::make_device_mdarray<float, uint32_t>(handle, mr, make_extents<uint32_t>(n_clusters));
      raft::linalg::rowNorm<float, IdxT>(
        centroidsNorm.data_handle(), centers, dim, n_clusters, raft::linalg::L2Norm, true, stream);

      raft::distance::fusedL2NNMinReduce<float, raft::KeyValuePair<IdxT, float>, IdxT>(
        minClusterAndDistance.data_handle(),
        dataset,
        centers,
        dataset_norm,
        centroidsNorm.data_handle(),
        n_rows,
        n_clusters,
        dim,
        (void*)workspace.data_handle(),
        (metric == raft::distance::DistanceType::L2Expanded) ? false : true,
        false,
        stream);

      // todo(lsugy): use KVP + iterator in caller.
      // Copy keys to output labels
      thrust::transform(handle.get_thrust_policy(),
                        minClusterAndDistance.data_handle(),
                        minClusterAndDistance.data_handle() + n_rows,
                        labels,
                        [=] __device__(raft::KeyValuePair<IdxT, float> kvp) {
                          return static_cast<LabelT>(kvp.key);
                        });
      break;
    }
    case raft::distance::DistanceType::InnerProduct: {
      // TODO: pass buffer
      rmm::device_uvector<float> distances(n_rows * n_clusters, stream, mr);

      float alpha = -1.0;
      float beta  = 0.0;

      linalg::gemm(handle,
                   true,
                   false,
                   n_clusters,
                   n_rows,
                   dim,
                   &alpha,
                   centers,
                   dim,
                   dataset,
                   dim,
                   &beta,
                   distances.data(),
                   n_clusters,
                   stream);
      utils::argmin_along_rows(
        n_rows, static_cast<IdxT>(n_clusters), distances.data(), labels, stream);
      break;
    }
    default: {
      RAFT_FAIL("The chosen distance metric is not supported (%d)", int(metric));
    }
  }
}

/**
 * @brief Suggest a minibatch size for kmeans prediction.
 *
 * This function is used as a heuristic to split the work over a large dataset
 * to reduce the size of temporary memory allocations.
 *
 * @param n_clusters number of clusters in kmeans clustering
 * @param n_rows dataset size
 * @return a suggested minibatch size
 */
template <typename IdxT>
constexpr inline auto calc_minibatch_size(uint32_t n_clusters,
                                          IdxT n_rows,
                                          uint32_t dim,
                                          raft::distance::DistanceType metric,
                                          bool is_float) -> IdxT
{
  n_clusters = std::max<uint32_t>(1, n_clusters);

  // Estimate memory needs per row (i.e element of the batch).
  IdxT mem_per_row = 0;
  /* fusedL2NN only needs one integer per row for a mutex.
   * Other metrics require storing a distance matrix. */
  if (metric != raft::distance::DistanceType::L2Expanded &&
      metric != raft::distance::DistanceType::L2SqrtExpanded) {
    mem_per_row += sizeof(float) * n_clusters;
  } else {
    mem_per_row += sizeof(int);
  }
  // If we need to convert to float, space required for the converted batch.
  if (!is_float) { mem_per_row += sizeof(float) * dim; }

  // Heuristic: calculate the minibatch size in order to use at most 1GB of memory.
  IdxT minibatch_size = (1 << 30) / mem_per_row;
  minibatch_size      = 64 * ceildiv(minibatch_size, (IdxT)64);
  minibatch_size      = std::min<IdxT>(minibatch_size, n_rows);
  return minibatch_size;
}

/**
 * @brief Given the data and labels, calculate cluster centers and sizes in one sweep.
 *
 * Let `S_i = {x_k | x_k \in dataset & labels[k] == i}` be the vectors in the dataset with label i.
 *
 * On exit,
 *   `centers_i = (\sum_{x \in S_i} x + w_i * center_i) / (|S_i| + w_i)`,
 *     where  `w_i = reset_counters ?  0 : cluster_size[i]`.
 *
 * In other words, the updated cluster centers are a weighted average of the existing cluster
 * center, and the coordinates of the points labeled with i. _This allows calling this function
 * multiple times with different datasets with the same effect as if calling this function once
 * on the combined dataset_.
 *
 * NB: all pointers must be accessible on the device.
 *
 * @tparam T      element type
 * @tparam IdxT   index type
 * @tparam LabelT label type
 *
 * @param[inout] centers pointer to the output [n_clusters, dim]
 * @param[inout] cluster_sizes number of rows in each cluster [n_clusters]
 * @param n_clusters number of clusters/centers
 * @param dim dimensionality of the data
 * @param[in] dataset a pointer to the data [n_rows, dim]
 * @param n_rows number samples in the `dataset`
 * @param[in] labels output predictions [n_rows]
 * @param reset_counters whether to clear the output arrays before calculating.
 *    When set to `false`, this function may be used to update existing centers and sizes using
 *    the weighted average principle.
 * @param stream
 * @param mr (optional) memory resource to use for temporary allocations on the device
 */
template <typename T, typename IdxT, typename LabelT>
void calc_centers_and_sizes(const handle_t& handle,
                            float* centers,
                            uint32_t* cluster_sizes,
                            uint32_t n_clusters,
                            uint32_t dim,
                            const T* dataset,
                            IdxT n_rows,
                            const LabelT* labels,
                            bool reset_counters,
                            rmm::cuda_stream_view stream,
                            rmm::mr::device_memory_resource* mr = nullptr)
{
  if (mr == nullptr) { mr = rmm::mr::get_current_device_resource(); }

  if (!reset_counters) {
    utils::map_along_rows(
      n_clusters,
      dim,
      centers,
      cluster_sizes,
      [] __device__(float c, uint32_t s) -> float { return c * s; },
      stream);
  }

  rmm::device_uvector<char> workspace(0, stream, mr);
  rmm::device_uvector<float> cluster_sizes_f(n_clusters, stream, mr);
  float* sizes_f = cluster_sizes_f.data();

  // If we reset the counters, we can compute directly the new sizes in cluster_sizes.
  // If we don't reset, we compute in a temporary buffer and add in a separate step.
  rmm::device_uvector<uint32_t> temp_cluster_sizes(0, stream, mr);
  uint32_t* temp_sizes = cluster_sizes;
  if (!reset_counters) {
    temp_cluster_sizes.resize(n_clusters, stream);
    temp_sizes = temp_cluster_sizes.data();
  }

  utils::mapping<float> mapping_op;
  cub::TransformInputIterator<float, utils::mapping<float>, const T*> mapping_itr(dataset,
                                                                                  mapping_op);

  // todo(lsugy): use iterator from KV output of fusedL2NN
  raft::linalg::reduce_rows_by_key(mapping_itr,
                                   static_cast<int64_t>(dim),
                                   labels,
                                   nullptr,
                                   static_cast<int64_t>(n_rows),
                                   static_cast<int64_t>(dim),
                                   static_cast<int64_t>(n_clusters),
                                   centers,
                                   stream,
                                   reset_counters);

  // Compute weight of each cluster
  raft::cluster::detail::countLabels(handle,
                                     labels,
                                     temp_sizes,
                                     static_cast<int64_t>(n_rows),
                                     static_cast<int64_t>(n_clusters),
                                     workspace);

  // Add previous sizes if necessary and cast to float
  auto counting = thrust::make_counting_iterator<int>(0);
  thrust::for_each(
    handle.get_thrust_policy(), counting, counting + n_clusters, [=] __device__(int idx) {
      uint32_t temp_size = temp_sizes[idx];
      if (!reset_counters) {
        temp_size += cluster_sizes[idx];
        cluster_sizes[idx] = temp_size;
      }
      sizes_f[idx] = static_cast<float>(temp_size);
    });

  raft::linalg::matrixVectorOp(
    centers,
    centers,
    sizes_f,
    static_cast<int64_t>(dim),
    static_cast<int64_t>(n_clusters),
    true,
    false,
    [=] __device__(float mat, float vec) {
      if (vec == 0.0f)
        return 0.0f;
      else
        return mat / vec;
    },
    stream);
}

/** Computes the L2 norm of the dataset, converting to float if necessary */
template <typename T, typename IdxT>
void compute_norm(float* dataset_norm,
                  const T* dataset,
                  IdxT dim,
                  IdxT n_rows,
                  rmm::cuda_stream_view stream,
                  rmm::mr::device_memory_resource* mr = nullptr)
{
  common::nvtx::range<common::nvtx::domain::raft> fun_scope("kmeans::compute_norm");
  if (mr == nullptr) { mr = rmm::mr::get_current_device_resource(); }
  rmm::device_uvector<float> dataset_float(0, stream, mr);

  const float* dataset_ptr = nullptr;

  if (std::is_same_v<float, T>) {
    dataset_ptr = reinterpret_cast<const float*>(dataset);
  } else {
    dataset_float.resize(n_rows * dim, stream);

    linalg::unaryOp(dataset_float.data(), dataset, n_rows * dim, utils::mapping<float>{}, stream);

    dataset_ptr = (const float*)dataset_float.data();
  }

  raft::linalg::rowNorm<float, IdxT>(
    dataset_norm, dataset_ptr, dim, n_rows, raft::linalg::L2Norm, true, stream);
}

/**
 * @brief Predict labels for the dataset.
 *
 * @tparam T      element type
 * @tparam IdxT   index type
 * @tparam LabelT label type
 *
 * @param handle
 * @param[in] centers a pointer to the row-major matrix of cluster centers [n_clusters, dim]
 * @param n_clusters number of clusters/centers
 * @param dim dimensionality of the data
 * @param[in] dataset a pointer to the data [n_rows, dim]
 * @param[in] dataset_norm pointer to the precomputed norm (for L2 metrics only) [n_rows]
 * @param n_rows number samples in the `dataset`
 * @param[out] labels output predictions [n_rows]
 * @param metric
 * @param stream
 * @param mr (optional) memory resource to use for temporary allocations
 */
template <typename T, typename IdxT, typename LabelT>
void predict(const handle_t& handle,
             const float* centers,
             uint32_t n_clusters,
             uint32_t dim,
             const T* dataset,
             IdxT n_rows,
             LabelT* labels,
             raft::distance::DistanceType metric,
             rmm::cuda_stream_view stream,
             rmm::mr::device_memory_resource* mr = nullptr,
             const float* dataset_norm           = nullptr)
{
  common::nvtx::range<common::nvtx::domain::raft> fun_scope(
    "kmeans::predict(%zu, %u)", static_cast<size_t>(n_rows), n_clusters);
  if (mr == nullptr) { mr = rmm::mr::get_current_device_resource(); }
  IdxT max_minibatch_size =
    calc_minibatch_size(n_clusters, n_rows, dim, metric, std::is_same_v<T, float>);
  rmm::device_uvector<float> cur_dataset(
    std::is_same_v<T, float> ? 0 : max_minibatch_size * dim, stream, mr);
  bool need_compute_norm =
    dataset_norm == nullptr && (metric == raft::distance::DistanceType::L2Expanded ||
                                metric == raft::distance::DistanceType::L2SqrtExpanded);
  rmm::device_uvector<float> cur_dataset_norm(
    need_compute_norm ? max_minibatch_size : 0, stream, mr);
  const float* dataset_norm_ptr = nullptr;
  auto cur_dataset_ptr          = cur_dataset.data();
  for (IdxT offset = 0; offset < n_rows; offset += max_minibatch_size) {
    IdxT minibatch_size = std::min<IdxT>(max_minibatch_size, n_rows - offset);

    if constexpr (std::is_same_v<T, float>) {
      cur_dataset_ptr = const_cast<float*>(dataset + offset * dim);
    } else {
      linalg::unaryOp(cur_dataset_ptr,
                      dataset + offset * dim,
                      (IdxT)(minibatch_size * dim),
                      utils::mapping<float>{},
                      stream);
    }

    // Compute the norm now if it hasn't been pre-computed.
    if (need_compute_norm) {
      compute_norm<float, IdxT>(
        cur_dataset_norm.data(), cur_dataset_ptr, (IdxT)dim, (IdxT)minibatch_size, stream, mr);
      dataset_norm_ptr = cur_dataset_norm.data();
    } else if (dataset_norm != nullptr) {
      dataset_norm_ptr = dataset_norm + offset;
    }

    predict_float_core<IdxT, LabelT>(handle,
                                     centers,
                                     n_clusters,
                                     dim,
                                     cur_dataset_ptr,
                                     dataset_norm_ptr,
                                     minibatch_size,
                                     labels + offset,
                                     metric,
                                     stream,
                                     mr);
  }
}

template <typename T, uint32_t BlockDimY, typename IdxT, typename LabelT>
__global__ void __launch_bounds__((WarpSize * BlockDimY))
  adjust_centers_kernel(float* centers,  // [n_clusters, dim]
                        uint32_t n_clusters,
                        uint32_t dim,
                        const T* dataset,  // [n_rows, dim]
                        IdxT n_rows,
                        const LabelT* labels,           // [n_rows]
                        const uint32_t* cluster_sizes,  // [n_clusters]
                        float threshold,
                        uint32_t average,
                        uint32_t seed,
                        uint32_t* count)
{
  uint32_t l = threadIdx.y + BlockDimY * blockIdx.y;
  if (l >= n_clusters) return;
  auto csize = cluster_sizes[l];
  // skip big clusters
  if (csize > static_cast<uint32_t>(average * threshold)) return;

  // choose a "random" i that belongs to a rather large cluster
  IdxT i;
  uint32_t j = laneId();
  if (j == 0) {
    do {
      auto old = static_cast<IdxT>(atomicAdd(count, 1));
      i        = (seed * (old + 1)) % n_rows;
    } while (cluster_sizes[labels[i]] < average);
  }
  i = raft::shfl(i, 0);

  // Adjust the center of the selected smaller cluster to gravitate towards
  // a sample from the selected larger cluster.
  const IdxT li = static_cast<IdxT>(labels[i]);
  // Weight of the current center for the weighted average.
  // We dump it for anomalously small clusters, but keep constant overwise.
  const float wc = csize > kAdjustCentersWeight ? kAdjustCentersWeight : float(csize);
  // Weight for the datapoint used to shift the center.
  const float wd = 1.0;
  for (; j < dim; j += WarpSize) {
    float val = 0;
    val += wc * centers[j + dim * li];
    val += wd * utils::mapping<float>{}(dataset[j + static_cast<IdxT>(dim) * i]);
    val /= wc + wd;
    centers[j + dim * l] = val;
  }
}

/**
 * @brief Adjust centers for clusters that have small number of entries.
 *
 * For each cluster, where the cluster size is not bigger than a threshold, the center is moved
 * towards a data point that belongs to a large cluster.
 *
 * NB: if this function returns `true`, you should update the labels.
 *
 * NB: all pointers are used either on the host side or on the device side together.
 *
 * @tparam T element type
 *
 * @param[inout] centers cluster centers [n_clusters, dim]
 * @param n_clusters number of rows in `centers`
 * @param dim number of columns in `centers` and `dataset`
 * @param[in] dataset a host pointer to the row-major data matrix [n_rows, dim]
 * @param n_rows number of rows in `dataset`
 * @param[in] labels a host pointer to the cluster indices [n_rows]
 * @param[in] cluster_sizes number of rows in each cluster [n_clusters]
 * @param threshold defines a criterion for adjusting a cluster
 *                   (cluster_sizes <= average_size * threshold)
 *                   0 <= threshold < 1
 * @param device_memory  memory resource to use for temporary allocations
 * @param stream
 *
 * @return whether any of the centers has been updated (and thus, `labels` need to be recalculated).
 */
template <typename T, typename IdxT, typename LabelT>
auto adjust_centers(float* centers,
                    uint32_t n_clusters,
                    uint32_t dim,
                    const T* dataset,
                    IdxT n_rows,
                    const LabelT* labels,
                    const uint32_t* cluster_sizes,
                    float threshold,
                    rmm::cuda_stream_view stream,
                    rmm::mr::device_memory_resource* device_memory) -> bool
{
  common::nvtx::range<common::nvtx::domain::raft> fun_scope(
    "kmeans::adjust_centers(%zu, %u)", static_cast<size_t>(n_rows), n_clusters);
  if (n_clusters == 0) { return false; }
  constexpr static std::array kPrimes{29,   71,   113,  173,  229,  281,  349,  409,  463,  541,
                                      601,  659,  733,  809,  863,  941,  1013, 1069, 1151, 1223,
                                      1291, 1373, 1451, 1511, 1583, 1657, 1733, 1811, 1889, 1987,
                                      2053, 2129, 2213, 2287, 2357, 2423, 2531, 2617, 2687, 2741};
  static IdxT i        = 0;
  static IdxT i_primes = 0;

  bool adjusted    = false;
  uint32_t average = static_cast<uint32_t>(n_rows / static_cast<IdxT>(n_clusters));
  uint32_t ofst;
  do {
    i_primes = (i_primes + 1) % kPrimes.size();
    ofst     = kPrimes[i_primes];
  } while (n_rows % ofst == 0);

  switch (utils::check_pointer_residency(centers, dataset, labels, cluster_sizes)) {
    case utils::pointer_residency::host_and_device:
    case utils::pointer_residency::device_only: {
      constexpr uint32_t kBlockDimY = 4;
      const dim3 block_dim(WarpSize, kBlockDimY, 1);
      const dim3 grid_dim(1, raft::ceildiv(n_clusters, kBlockDimY), 1);
      rmm::device_scalar<uint32_t> update_count(0, stream, device_memory);
      adjust_centers_kernel<T, kBlockDimY><<<grid_dim, block_dim, 0, stream>>>(centers,
                                                                               n_clusters,
                                                                               dim,
                                                                               dataset,
                                                                               n_rows,
                                                                               labels,
                                                                               cluster_sizes,
                                                                               threshold,
                                                                               average,
                                                                               ofst,
                                                                               update_count.data());
      adjusted = update_count.value(stream) > 0;  // NB: rmm scalar performs the sync
    } break;
    case utils::pointer_residency::host_only: {
      stream.synchronize();
      for (uint32_t l = 0; l < n_clusters; l++) {
        auto csize = cluster_sizes[l];
        // skip big clusters
        if (csize > static_cast<uint32_t>(average * threshold)) continue;
        // choose a "random" i that belongs to a rather large cluster
        do {
          i = (i + ofst) % n_rows;
        } while (cluster_sizes[labels[i]] < average);
        // Adjust the center of the selected smaller cluster to gravitate towards
        // a sample from the selected larger cluster.
        const IdxT li = static_cast<IdxT>(labels[i]);
        // Weight of the current center for the weighted average.
        // We dump it for anomalously small clusters, but keep constant overwise.
        const float wc = std::min<float>(csize, kAdjustCentersWeight);
        // Weight for the datapoint used to shift the center.
        const float wd = 1.0;
        for (uint32_t j = 0; j < dim; j++) {
          float val = 0;
          val += wc * centers[j + dim * li];
          val += wd * utils::mapping<float>{}(dataset[j + static_cast<IdxT>(dim) * i]);
          val /= wc + wd;
          centers[j + dim * l] = val;
        }
        adjusted = true;
      }
      stream.synchronize();
    } break;
    default: RAFT_FAIL("All pointers must reside on the same side, host or device.");
  }
  return adjusted;
}

/**
 * @brief Expectation-maximization-balancing combined in an iterative process.
 *
 * Note, the `cluster_centers` is assumed to be already initialized here.
 * Thus, this function can be used for fine-tuning existing clusters;
 * to train from scratch, use `build_clusters` function below.
 *
 * @tparam T      element type
 * @tparam IdxT   index type
 * @tparam LabelT label type
 *
 * @param handle
 * @param n_iters the requested number of iteration
 * @param dim the dimensionality of the dataset
 * @param[in] dataset a pointer to a managed row-major array [n_rows, dim]
 * @param[in] dataset_norm pointer to the precomputed norm (for L2 metrics only) [n_rows]
 * @param n_rows the number of rows in the dataset
 * @param n_cluster the requested number of clusters
 * @param[inout] cluster_centers a pointer to a managed row-major array [n_clusters, dim]
 * @param[out] cluster_labels a pointer to a managed row-major array [n_rows]
 * @param[out] cluster_sizes a pointer to a managed row-major array [n_clusters]
 * @param metric the distance type (there is a tweak in place for the similarity-based metrics)
 * @param balancing_pullback
 *   if the cluster centers are rebalanced on this number of iterations,
 *   one extra iteration is performed (this could happen several times) (default should be `2`).
 *   In other words, the first and then every `ballancing_pullback`-th rebalancing operation adds
 *   one more iteration to the main cycle.
 * @param balancing_threshold
 *   the rebalancing takes place if any cluster is smaller than `avg_size * balancing_threshold`
 *   on a given iteration (default should be `~ 0.25`).
 * @param stream
 * @param device_memory
 *   a memory resource for device allocations (makes sense to provide a memory pool here)
 */
template <typename T, typename IdxT, typename LabelT>
void balancing_em_iters(const handle_t& handle,
                        uint32_t n_iters,
                        uint32_t dim,
                        const T* dataset,
                        const float* dataset_norm,
                        IdxT n_rows,
                        uint32_t n_clusters,
                        float* cluster_centers,
                        LabelT* cluster_labels,
                        uint32_t* cluster_sizes,
                        raft::distance::DistanceType metric,
                        uint32_t balancing_pullback,
                        float balancing_threshold,
                        rmm::cuda_stream_view stream,
                        rmm::mr::device_memory_resource* device_memory)
{
  uint32_t balancing_counter = balancing_pullback;
  for (uint32_t iter = 0; iter < n_iters; iter++) {
    // Balancing step - move the centers around to equalize cluster sizes
    // (but not on the first iteration)
    if (iter > 0 && kmeans::adjust_centers(cluster_centers,
                                           n_clusters,
                                           dim,
                                           dataset,
                                           n_rows,
                                           cluster_labels,
                                           cluster_sizes,
                                           balancing_threshold,
                                           stream,
                                           device_memory)) {
      if (balancing_counter++ >= balancing_pullback) {
        balancing_counter -= balancing_pullback;
        n_iters++;
      }
    }
    switch (metric) {
      // For some metrics, cluster calculation and adjustment tends to favor zero center vectors.
      // To avoid converging to zero, we normalize the center vectors on every iteration.
      case raft::distance::DistanceType::InnerProduct:
      case raft::distance::DistanceType::CosineExpanded:
      case raft::distance::DistanceType::CorrelationExpanded:
        utils::normalize_rows<uint32_t>(n_clusters, dim, cluster_centers, stream);
      default: break;
    }
    // E: Expectation step - predict labels
    predict<T, IdxT, LabelT>(handle,
                             cluster_centers,
                             n_clusters,
                             dim,
                             dataset,
                             n_rows,
                             cluster_labels,
                             metric,
                             stream,
                             device_memory,
                             dataset_norm);
    // M: Maximization step - calculate optimal cluster centers
    calc_centers_and_sizes(handle,
                           cluster_centers,
                           cluster_sizes,
                           n_clusters,
                           dim,
                           dataset,
                           n_rows,
                           cluster_labels,
                           true,
                           stream,
                           device_memory);
  }
}

/** Randomly initialize cluster centers and then call `balancing_em_iters`. */
template <typename T, typename IdxT, typename LabelT>
void build_clusters(const handle_t& handle,
                    uint32_t n_iters,
                    uint32_t dim,
                    const T* dataset,
                    IdxT n_rows,
                    uint32_t n_clusters,
                    float* cluster_centers,
                    LabelT* cluster_labels,
                    uint32_t* cluster_sizes,
                    raft::distance::DistanceType metric,
                    rmm::cuda_stream_view stream,
                    rmm::mr::device_memory_resource* device_memory,
                    const float* dataset_norm = nullptr)
{
  RAFT_EXPECTS(static_cast<uint64_t>(n_rows) * static_cast<uint64_t>(dim) <=
                 static_cast<uint64_t>(std::numeric_limits<IdxT>::max()),
               "the chosen index type cannot represent all indices for the given dataset");

  // "randomly initialize labels"
  auto f = [n_clusters] __device__(LabelT * out, IdxT i) {
    *out = LabelT(i % static_cast<IdxT>(n_clusters));
  };
  linalg::writeOnlyUnaryOp<LabelT, decltype(f), IdxT>(cluster_labels, n_rows, f, stream);

  // update centers to match the initialized labels.
  calc_centers_and_sizes(handle,
                         cluster_centers,
                         cluster_sizes,
                         n_clusters,
                         dim,
                         dataset,
                         n_rows,
                         cluster_labels,
                         true,
                         stream,
                         device_memory);

  // run EM
  balancing_em_iters<T, IdxT, LabelT>(handle,
                                      n_iters,
                                      dim,
                                      dataset,
                                      dataset_norm,
                                      n_rows,
                                      n_clusters,
                                      cluster_centers,
                                      cluster_labels,
                                      cluster_sizes,
                                      metric,
                                      2,
                                      0.25f,
                                      stream,
                                      device_memory);
}

/** Calculate how many fine clusters should belong to each mesocluster. */
template <typename IdxT>
inline auto arrange_fine_clusters(uint32_t n_clusters,
                                  uint32_t n_mesoclusters,
                                  IdxT n_rows,
                                  const uint32_t* mesocluster_sizes)
{
  std::vector<uint32_t> fine_clusters_nums(n_mesoclusters);
  std::vector<uint32_t> fine_clusters_csum(n_mesoclusters + 1);
  fine_clusters_csum[0] = 0;

  uint32_t n_lists_rem       = n_clusters;
  uint32_t n_nonempty_ms_rem = 0;
  for (uint32_t i = 0; i < n_mesoclusters; i++) {
    n_nonempty_ms_rem += mesocluster_sizes[i] > 0 ? 1 : 0;
  }
  IdxT n_rows_rem                 = n_rows;
  IdxT mesocluster_size_sum       = 0;
  uint32_t mesocluster_size_max   = 0;
  uint32_t fine_clusters_nums_max = 0;
  for (uint32_t i = 0; i < n_mesoclusters; i++) {
    if (i < n_mesoclusters - 1) {
      // Although the algorithm is meant to produce balanced clusters, when something
      // goes wrong, we may get empty clusters (e.g. during development/debugging).
      // The code below ensures a proportional arrangement of fine cluster numbers
      // per mesocluster, even if some clusters are empty.
      if (mesocluster_sizes[i] == 0) {
        fine_clusters_nums[i] = 0;
      } else {
        n_nonempty_ms_rem--;
        auto s = uint32_t((double)n_lists_rem * mesocluster_sizes[i] / n_rows_rem + .5);
        s      = std::min<uint32_t>(s, n_lists_rem - n_nonempty_ms_rem);
        fine_clusters_nums[i] = std::max<uint32_t>(s, 1);
      }
    } else {
      fine_clusters_nums[i] = n_lists_rem;
    }
    n_lists_rem -= fine_clusters_nums[i];
    n_rows_rem -= mesocluster_sizes[i];
    mesocluster_size_max = max(mesocluster_size_max, mesocluster_sizes[i]);
    mesocluster_size_sum += mesocluster_sizes[i];
    fine_clusters_nums_max    = max(fine_clusters_nums_max, fine_clusters_nums[i]);
    fine_clusters_csum[i + 1] = fine_clusters_csum[i] + fine_clusters_nums[i];
  }

  RAFT_EXPECTS(mesocluster_size_sum == n_rows,
               "mesocluster sizes do not add up (%zu) to the total trainset size (%zu)",
               static_cast<size_t>(mesocluster_size_sum),
               static_cast<size_t>(n_rows));
  RAFT_EXPECTS(fine_clusters_csum[n_mesoclusters] == n_clusters,
               "fine cluster numbers do not add up (%u) to the total number of clusters (%u)",
               fine_clusters_csum[n_mesoclusters],
               n_clusters);

  return std::make_tuple(mesocluster_size_max,
                         fine_clusters_nums_max,
                         std::move(fine_clusters_nums),
                         std::move(fine_clusters_csum));
}

/**
 *  Given the (coarse) mesoclusters and the distribution of fine clusters within them,
 *  build the fine clusters.
 *
 *  Processing one mesocluster at a time:
 *   1. Copy mesocluster data into a separate buffer
 *   2. Predict fine cluster
 *   3. Refince the fine cluster centers
 *
 *  As a result, the fine clusters are what is returned by `build_hierarchical`;
 *  this function returns the total number of fine clusters, which can be checked to be
 *  the same as the requested number of clusters.
 */
template <typename T, typename IdxT, typename LabelT>
auto build_fine_clusters(const handle_t& handle,
                         uint32_t n_iters,
                         uint32_t dim,
                         const T* dataset_mptr,
                         const float* dataset_norm_mptr,
                         const LabelT* labels_mptr,
                         IdxT n_rows,
                         const uint32_t* fine_clusters_nums,
                         const uint32_t* fine_clusters_csum,
                         const uint32_t* mesocluster_sizes,
                         uint32_t n_mesoclusters,
                         uint32_t mesocluster_size_max,
                         uint32_t fine_clusters_nums_max,
                         float* cluster_centers,
                         raft::distance::DistanceType metric,
                         rmm::mr::device_memory_resource* managed_memory,
                         rmm::mr::device_memory_resource* device_memory,
                         rmm::cuda_stream_view stream) -> uint32_t
{
  rmm::device_uvector<IdxT> mc_trainset_ids_buf(mesocluster_size_max, stream, managed_memory);
  rmm::device_uvector<float> mc_trainset_buf(mesocluster_size_max * dim, stream, device_memory);
  rmm::device_uvector<float> mc_trainset_norm_buf(mesocluster_size_max, stream, device_memory);
  auto mc_trainset_ids  = mc_trainset_ids_buf.data();
  auto mc_trainset      = mc_trainset_buf.data();
  auto mc_trainset_norm = mc_trainset_norm_buf.data();

  // label (cluster ID) of each vector
  rmm::device_uvector<LabelT> mc_trainset_labels(mesocluster_size_max, stream, device_memory);

  rmm::device_uvector<float> mc_trainset_ccenters(
    fine_clusters_nums_max * dim, stream, device_memory);
  // number of vectors in each cluster
  rmm::device_uvector<uint32_t> mc_trainset_csizes_tmp(
    fine_clusters_nums_max, stream, device_memory);

  // Training clusters in each meso-cluster
  uint32_t n_clusters_done = 0;
  for (uint32_t i = 0; i < n_mesoclusters; i++) {
    uint32_t k = 0;
    for (IdxT j = 0; j < n_rows; j++) {
      if (labels_mptr[j] == (LabelT)i) { mc_trainset_ids[k++] = j; }
    }
    if (k != mesocluster_sizes[i])
      RAFT_LOG_WARN("Incorrect mesocluster size at %d. %d vs %d", i, k, mesocluster_sizes[i]);
    if (k == 0) {
      RAFT_LOG_DEBUG("Empty cluster %d", i);
      RAFT_EXPECTS(fine_clusters_nums[i] == 0,
                   "Number of fine clusters must be zero for the empty mesocluster (got %d)",
                   fine_clusters_nums[i]);
      continue;
    } else {
      RAFT_EXPECTS(fine_clusters_nums[i] > 0,
                   "Number of fine clusters must be non-zero for a non-empty mesocluster");
    }

    utils::copy_selected((IdxT)mesocluster_sizes[i],
                         (IdxT)dim,
                         dataset_mptr,
                         mc_trainset_ids,
                         (IdxT)dim,
                         mc_trainset,
                         (IdxT)dim,
                         stream);
    if (metric == raft::distance::DistanceType::L2Expanded ||
        metric == raft::distance::DistanceType::L2SqrtExpanded) {
      thrust::gather(handle.get_thrust_policy(),
                     mc_trainset_ids,
                     mc_trainset_ids + mesocluster_sizes[i],
                     dataset_norm_mptr,
                     mc_trainset_norm);
    }

    build_clusters<float, IdxT, LabelT>(handle,
                                        n_iters,
                                        dim,
                                        mc_trainset,
                                        mesocluster_sizes[i],
                                        fine_clusters_nums[i],
                                        mc_trainset_ccenters.data(),
                                        mc_trainset_labels.data(),
                                        mc_trainset_csizes_tmp.data(),
                                        metric,
                                        stream,
                                        device_memory,
                                        mc_trainset_norm);

    raft::copy(cluster_centers + (dim * fine_clusters_csum[i]),
               mc_trainset_ccenters.data(),
               fine_clusters_nums[i] * dim,
               stream);
    handle.sync_stream(stream);
    n_clusters_done += fine_clusters_nums[i];
  }
  return n_clusters_done;
}

/**
 * @brief Hierarchical balanced k-means
 *
 * @tparam T      element type
 * @tparam IdxT   index type
 * @tparam LabelT label type
 *
 * @param handle
 * @param n_iters number of training iterations
 * @param dim number of columns in `centers` and `dataset`
 * @param[in] dataset a device pointer to the source dataset [n_rows, dim]
 * @param n_rows number of rows in the input
 * @param[out] cluster_centers a device pointer to the found cluster centers [n_cluster, dim]
 * @param n_cluster
 * @param metric the distance type
 * @param stream
 */
template <typename T, typename IdxT>
void build_hierarchical(const handle_t& handle,
                        uint32_t n_iters,
                        uint32_t dim,
                        const T* dataset,
                        IdxT n_rows,
                        float* cluster_centers,
                        uint32_t n_clusters,
                        raft::distance::DistanceType metric,
                        rmm::cuda_stream_view stream)
{
  using LabelT = uint32_t;

  RAFT_EXPECTS(static_cast<uint64_t>(n_rows) * static_cast<uint64_t>(dim) <=
                 static_cast<uint64_t>(std::numeric_limits<IdxT>::max()),
               "the chosen index type cannot represent all indices for the given dataset");

  common::nvtx::range<common::nvtx::domain::raft> fun_scope(
    "kmeans::build_hierarchical(%zu, %u)", static_cast<size_t>(n_rows), n_clusters);

  uint32_t n_mesoclusters = std::min<uint32_t>(n_clusters, std::sqrt(n_clusters) + 0.5);
  RAFT_LOG_DEBUG("kmeans::build_hierarchical: n_mesoclusters: %u", n_mesoclusters);

  rmm::mr::managed_memory_resource managed_memory;
  rmm::mr::device_memory_resource* device_memory = nullptr;
  IdxT max_minibatch_size =
    calc_minibatch_size(n_clusters, n_rows, dim, metric, std::is_same_v<T, float>);
  auto pool_guard = raft::get_pool_memory_resource(device_memory, max_minibatch_size * dim * 4);
  if (pool_guard) {
    RAFT_LOG_DEBUG(
      "kmeans::build_hierarchical: using pool memory resource with initial size %zu bytes",
      pool_guard->pool_size());
  }

  // Precompute the L2 norm of the dataset if relevant.
  const float* dataset_norm = nullptr;
  rmm::device_uvector<float> dataset_norm_buf(0, stream, device_memory);
  if (metric == raft::distance::DistanceType::L2Expanded ||
      metric == raft::distance::DistanceType::L2SqrtExpanded) {
    dataset_norm_buf.resize(n_rows, stream);
    for (IdxT offset = 0; offset < n_rows; offset += max_minibatch_size) {
      IdxT minibatch_size = std::min<IdxT>(max_minibatch_size, n_rows - offset);
      compute_norm<T, IdxT>(dataset_norm_buf.data() + offset,
                            dataset + dim * offset,
                            (IdxT)dim,
                            (IdxT)minibatch_size,
                            stream,
                            device_memory);
    }
    dataset_norm = (const float*)dataset_norm_buf.data();
  }

  // build coarse clusters (mesoclusters)
  rmm::device_uvector<LabelT> mesocluster_labels_buf(n_rows, stream, &managed_memory);
  rmm::device_uvector<uint32_t> mesocluster_sizes_buf(n_mesoclusters, stream, &managed_memory);
  {
    rmm::device_uvector<float> mesocluster_centers_buf(n_mesoclusters * dim, stream, device_memory);
    build_clusters<T, IdxT, LabelT>(handle,
                                    n_iters,
                                    dim,
                                    dataset,
                                    n_rows,
                                    n_mesoclusters,
                                    mesocluster_centers_buf.data(),
                                    mesocluster_labels_buf.data(),
                                    mesocluster_sizes_buf.data(),
                                    metric,
                                    stream,
                                    device_memory,
                                    dataset_norm);
  }

  auto mesocluster_sizes  = mesocluster_sizes_buf.data();
  auto mesocluster_labels = mesocluster_labels_buf.data();

  handle.sync_stream(stream);

  // build fine clusters
  auto [mesocluster_size_max, fine_clusters_nums_max, fine_clusters_nums, fine_clusters_csum] =
    arrange_fine_clusters(n_clusters, n_mesoclusters, n_rows, mesocluster_sizes);

  if (mesocluster_size_max * n_mesoclusters > 2 * n_rows) {
    RAFT_LOG_WARN("build_hierarchical: built unbalanced mesoclusters");
    RAFT_LOG_TRACE_VEC(mesocluster_sizes, n_mesoclusters);
    RAFT_LOG_TRACE_VEC(fine_clusters_nums.data(), n_mesoclusters);
  }

  auto n_clusters_done = build_fine_clusters<T, IdxT, LabelT>(handle,
                                                              n_iters,
                                                              dim,
                                                              dataset,
                                                              dataset_norm,
                                                              mesocluster_labels,
                                                              n_rows,
                                                              fine_clusters_nums.data(),
                                                              fine_clusters_csum.data(),
                                                              mesocluster_sizes,
                                                              n_mesoclusters,
                                                              mesocluster_size_max,
                                                              fine_clusters_nums_max,
                                                              cluster_centers,
                                                              metric,
                                                              &managed_memory,
                                                              device_memory,
                                                              stream);
  RAFT_EXPECTS(n_clusters_done == n_clusters, "Didn't process all clusters.");

  rmm::device_uvector<uint32_t> cluster_sizes(n_clusters, stream, device_memory);
  rmm::device_uvector<LabelT> labels(n_rows, stream, device_memory);

  // Fine-tuning kmeans for all clusters
  //
  // (*) Since the likely cluster centroids have been calculated
  // hierarchically already, the number of iteration for fine-tuning
  // kmeans for whole clusters should be reduced. However, there
  // is a possibility that the clusters could be unbalanced here,
  // in which case the actual number of iterations would be increased.
  //
  balancing_em_iters<T, IdxT, LabelT>(handle,
                                      std::max<uint32_t>(n_iters / 10, 2),
                                      dim,
                                      dataset,
                                      dataset_norm,
                                      n_rows,
                                      n_clusters,
                                      cluster_centers,
                                      labels.data(),
                                      cluster_sizes.data(),
                                      metric,
                                      5,
                                      0.2f,
                                      stream,
                                      device_memory);
}

}  // namespace raft::spatial::knn::detail::kmeans
