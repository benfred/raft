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

#include <raft/distance/distance.cuh>
#include <raft/distance/distance_types.hpp>
#include <raft/util/cuda_utils.cuh>
#include <raft/util/cudart_utils.hpp>

#include <rmm/cuda_stream_view.hpp>

namespace raft::spatial::knn::detail::utils {

/** Whether pointers are accessible on the device or on the host. */
enum class pointer_residency {
  /** Some of the pointers are on the device, some on the host. */
  mixed,
  /** All pointers accessible from both the device and the host. */
  host_and_device,
  /** All pointers are host accessible. */
  host_only,
  /** All poitners are device accessible. */
  device_only
};

template <typename... Types>
struct pointer_residency_count {
};

template <>
struct pointer_residency_count<> {
  static inline auto run() -> std::tuple<int, int> { return std::make_tuple(0, 0); }
};

template <typename Type, typename... Types>
struct pointer_residency_count<Type, Types...> {
  static inline auto run(const Type* ptr, const Types*... ptrs) -> std::tuple<int, int>
  {
    auto [on_device, on_host] = pointer_residency_count<Types...>::run(ptrs...);
    cudaPointerAttributes attr;
    RAFT_CUDA_TRY(cudaPointerGetAttributes(&attr, ptr));
    switch (attr.type) {
      case cudaMemoryTypeUnregistered:
      case cudaMemoryTypeHost: return std::make_tuple(on_device, on_host + 1);
      case cudaMemoryTypeDevice: return std::make_tuple(on_device + 1, on_host);
      case cudaMemoryTypeManaged: return std::make_tuple(on_device + 1, on_host + 1);
      default: return std::make_tuple(on_device, on_host);
    }
  }
};

/** Check if all argument pointers reside on the host or on the device. */
template <typename... Types>
auto check_pointer_residency(const Types*... ptrs) -> pointer_residency
{
  auto [on_device, on_host] = pointer_residency_count<Types...>::run(ptrs...);
  int n_args                = sizeof...(Types);
  if (on_device == n_args && on_host == n_args) { return pointer_residency::host_and_device; }
  if (on_device == n_args) { return pointer_residency::device_only; }
  if (on_host == n_args) { return pointer_residency::host_only; }
  return pointer_residency::mixed;
}

template <typename T>
struct config {
};

template <>
struct config<float> {
  using value_t                    = float;
  static constexpr double kDivisor = 1.0;
};
template <>
struct config<uint8_t> {
  using value_t                    = uint32_t;
  static constexpr double kDivisor = 256.0;
};
template <>
struct config<int8_t> {
  using value_t                    = int32_t;
  static constexpr double kDivisor = 128.0;
};

/**
 * @brief Converting values between the types taking into account scaling factors
 * for the integral types.
 *
 * @tparam T target type of the mapping.
 */
template <typename T>
struct mapping {
  /**
   * @defgroup
   * @brief Cast and possibly scale a value of the source type `S` to the target type `T`.
   *
   * @tparam S source type
   * @param x source value
   * @{
   */
  template <typename S>
  HDI auto operator()(const S& x) const -> std::enable_if_t<std::is_same_v<S, T>, T>
  {
    return x;
  };

  template <typename S>
  HDI auto operator()(const S& x) const -> std::enable_if_t<!std::is_same_v<S, T>, T>
  {
    constexpr double kMult = config<T>::kDivisor / config<S>::kDivisor;
    if constexpr (std::is_floating_point_v<S>) { return static_cast<T>(x * static_cast<S>(kMult)); }
    if constexpr (std::is_floating_point_v<T>) { return static_cast<T>(x) * static_cast<T>(kMult); }
    return static_cast<T>(static_cast<float>(x) * static_cast<float>(kMult));
  };
  /** @} */
};

/**
 * @brief Sets the first num bytes of the block of memory pointed by ptr to the specified value.
 *
 * @param[out] ptr host or device pointer
 * @param[in] value
 * @param[in] n_bytes
 */
template <typename T, typename IdxT>
inline void memzero(T* ptr, IdxT n_elems, rmm::cuda_stream_view stream)
{
  switch (check_pointer_residency(ptr)) {
    case pointer_residency::host_and_device:
    case pointer_residency::device_only: {
      RAFT_CUDA_TRY(cudaMemsetAsync(ptr, 0, n_elems * sizeof(T), stream));
    } break;
    case pointer_residency::host_only: {
      stream.synchronize();
      ::memset(ptr, 0, n_elems * sizeof(T));
    } break;
    default: RAFT_FAIL("memset: unreachable code");
  }
}

template <typename IdxT, typename OutT>
__global__ void argmin_along_rows_kernel(IdxT n_rows, uint32_t n_cols, const float* a, OutT* out)
{
  __shared__ OutT shm_ids[1024];    // NOLINT
  __shared__ float shm_vals[1024];  // NOLINT
  IdxT i = blockIdx.x;
  if (i >= n_rows) return;
  OutT min_idx  = n_cols;
  float min_val = raft::upper_bound<float>();
  for (OutT j = threadIdx.x; j < n_cols; j += blockDim.x) {
    if (min_val > a[j + n_cols * i]) {
      min_val = a[j + n_cols * i];
      min_idx = j;
    }
  }
  shm_vals[threadIdx.x] = min_val;
  shm_ids[threadIdx.x]  = min_idx;
  __syncthreads();
  for (IdxT offset = blockDim.x / 2; offset > 0; offset >>= 1) {
    if (threadIdx.x < offset) {
      if (shm_vals[threadIdx.x] < shm_vals[threadIdx.x + offset]) {
      } else if (shm_vals[threadIdx.x] > shm_vals[threadIdx.x + offset]) {
        shm_vals[threadIdx.x] = shm_vals[threadIdx.x + offset];
        shm_ids[threadIdx.x]  = shm_ids[threadIdx.x + offset];
      } else if (shm_ids[threadIdx.x] > shm_ids[threadIdx.x + offset]) {
        shm_ids[threadIdx.x] = shm_ids[threadIdx.x + offset];
      }
    }
    __syncthreads();
  }
  if (threadIdx.x == 0) { out[i] = shm_ids[0]; }
}

/**
 * @brief Find index of the smallest element in each row.
 *
 * NB: device-only function
 * TODO: specialize select_k for the case of `k == 1` and use that one instead.
 *
 * @tparam IdxT index type
 * @tparam OutT output type
 *
 * @param n_rows
 * @param n_cols
 * @param[in] a device pointer to the row-major matrix [n_rows, n_cols]
 * @param[out] out device pointer to the vector of selected indices [n_rows]
 * @param stream
 */
template <typename IdxT, typename OutT>
inline void argmin_along_rows(
  IdxT n_rows, IdxT n_cols, const float* a, OutT* out, rmm::cuda_stream_view stream)
{
  IdxT block_dim = 1024;
  while (block_dim > n_cols) {
    block_dim /= 2;
  }
  block_dim = max(block_dim, (IdxT)128);
  argmin_along_rows_kernel<IdxT, OutT><<<n_rows, block_dim, 0, stream>>>(n_rows, n_cols, a, out);
}

template <typename IdxT>
__global__ void dots_along_rows_kernel(IdxT n_rows, IdxT n_cols, const float* a, float* out)
{
  IdxT i = threadIdx.y + (blockDim.y * static_cast<IdxT>(blockIdx.x));
  if (i >= n_rows) return;

  float sqsum = 0.0;
  for (IdxT j = threadIdx.x; j < n_cols; j += blockDim.x) {
    float val = a[j + (n_cols * i)];
    sqsum += val * val;
  }
  sqsum += __shfl_xor_sync(0xffffffff, sqsum, 1);
  sqsum += __shfl_xor_sync(0xffffffff, sqsum, 2);
  sqsum += __shfl_xor_sync(0xffffffff, sqsum, 4);
  sqsum += __shfl_xor_sync(0xffffffff, sqsum, 8);
  sqsum += __shfl_xor_sync(0xffffffff, sqsum, 16);
  if (threadIdx.x == 0) { out[i] = sqsum; }
}

/**
 * @brief Square sum of values in each row (row-major matrix).
 *
 * NB: device-only function
 *
 * @tparam IdxT index type
 *
 * @param n_rows
 * @param n_cols
 * @param[in] a device pointer to the row-major matrix [n_rows, n_cols]
 * @param[out] out device pointer to the vector of dot-products [n_rows]
 * @param stream
 */
template <typename IdxT>
inline void dots_along_rows(
  IdxT n_rows, IdxT n_cols, const float* a, float* out, rmm::cuda_stream_view stream)
{
  dim3 threads(32, 4, 1);
  dim3 blocks(ceildiv<IdxT>(n_rows, threads.y), 1, 1);
  dots_along_rows_kernel<IdxT><<<blocks, threads, 0, stream>>>(n_rows, n_cols, a, out);
  /**
   * TODO: this can be replaced with the rowNorm helper as shown below.
   * However, the rowNorm helper seems to incur a significant performance penalty
   * (example case ann-search slowed down from 150ms to 186ms).
   *
   * raft::linalg::rowNorm(out, a, n_cols, n_rows, raft::linalg::L2Norm, true, stream);
   */
}

template <typename IdxT>
__global__ void normalize_rows_kernel(IdxT n_rows, IdxT n_cols, float* a)
{
  IdxT i = threadIdx.y + (blockDim.y * static_cast<IdxT>(blockIdx.x));
  if (i >= n_rows) return;

  float sqsum = 0.0;
  for (IdxT j = threadIdx.x; j < n_cols; j += blockDim.x) {
    float val = a[j + (n_cols * i)];
    sqsum += val * val;
  }
  sqsum += __shfl_xor_sync(0xffffffff, sqsum, 1);
  sqsum += __shfl_xor_sync(0xffffffff, sqsum, 2);
  sqsum += __shfl_xor_sync(0xffffffff, sqsum, 4);
  sqsum += __shfl_xor_sync(0xffffffff, sqsum, 8);
  sqsum += __shfl_xor_sync(0xffffffff, sqsum, 16);
  if (sqsum <= 1e-8) return;
  sqsum = rsqrtf(sqsum);  // reciprocal of the square root
  for (IdxT j = threadIdx.x; j < n_cols; j += blockDim.x) {
    a[j + n_cols * i] *= sqsum;
  }
}

/**
 * @brief Divide rows by their L2 norm (square root of sum of squares).
 *
 * NB: device-only function
 *
 * @tparam IdxT index type
 *
 * @param[in] n_rows
 * @param[in] n_cols
 * @param[inout] a device pointer to a row-major matrix [n_rows, n_cols]
 * @param stream
 */
template <typename IdxT>
inline void normalize_rows(IdxT n_rows, IdxT n_cols, float* a, rmm::cuda_stream_view stream)
{
  dim3 threads(32, 4, 1);  // DO NOT CHANGE
  dim3 blocks(ceildiv(n_rows, threads.y), 1, 1);
  normalize_rows_kernel<IdxT><<<blocks, threads, 0, stream>>>(n_rows, n_cols, a);
}

template <typename IdxT, typename Lambda>
__global__ void map_along_rows_kernel(
  IdxT n_rows, uint32_t n_cols, float* a, const uint32_t* d, Lambda map)
{
  IdxT gid = threadIdx.x + blockDim.x * static_cast<IdxT>(blockIdx.x);
  IdxT i   = gid / n_cols;
  if (i >= n_rows) return;
  float& x = a[gid];
  x        = map(x, d[i]);
}

/**
 * @brief Map a binary function over a matrix and a vector element-wise, broadcasting the vector
 * values along rows: `m[i, j] = op(m[i,j], v[i])`
 *
 * NB: device-only function
 *
 * @tparam IdxT   index type
 * @tparam Lambda
 *
 * @param n_rows
 * @param n_cols
 * @param[inout] m device pointer to a row-major matrix [n_rows, n_cols]
 * @param[in] v device pointer to a vector [n_rows]
 * @param op the binary operation to apply on every element of matrix rows and of the vector
 */
template <typename IdxT, typename Lambda>
inline void map_along_rows(IdxT n_rows,
                           uint32_t n_cols,
                           float* m,
                           const uint32_t* v,
                           Lambda op,
                           rmm::cuda_stream_view stream)
{
  dim3 threads(128, 1, 1);
  dim3 blocks(ceildiv<IdxT>(n_rows * n_cols, threads.x), 1, 1);
  map_along_rows_kernel<<<blocks, threads, 0, stream>>>(n_rows, n_cols, m, v, op);
}

template <typename T, typename IdxT>
__global__ void outer_add_kernel(const T* a, IdxT len_a, const T* b, IdxT len_b, T* c)
{
  IdxT gid = threadIdx.x + blockDim.x * static_cast<IdxT>(blockIdx.x);
  IdxT i   = gid / len_b;
  IdxT j   = gid % len_b;
  if (i >= len_a) return;
  c[gid] = (a == nullptr ? T(0) : a[i]) + (b == nullptr ? T(0) : b[j]);
}

template <typename T, typename IdxT>
__global__ void block_copy_kernel(const IdxT* in_offsets,
                                  const IdxT* out_offsets,
                                  IdxT n_blocks,
                                  const T* in_data,
                                  T* out_data,
                                  IdxT n_mult)
{
  IdxT i = static_cast<IdxT>(blockDim.x) * static_cast<IdxT>(blockIdx.x) + threadIdx.x;
  // find the source offset using the binary search.
  uint32_t l     = 0;
  uint32_t r     = n_blocks;
  IdxT in_offset = 0;
  if (in_offsets[r] * n_mult <= i) return;
  while (l + 1 < r) {
    uint32_t c = (l + r) >> 1;
    IdxT o     = in_offsets[c] * n_mult;
    if (o <= i) {
      l         = c;
      in_offset = o;
    } else {
      r = c;
    }
  }
  // copy the data
  out_data[out_offsets[l] * n_mult - in_offset + i] = in_data[i];
}

/**
 * Copy chunks of data from one array to another at given offsets.
 *
 * @tparam T element type
 * @tparam IdxT index type
 *
 * @param[in] in_offsets
 * @param[in] out_offsets
 * @param n_blocks size of the offset arrays minus one.
 * @param[in] in_data
 * @param[out] out_data
 * @param n_mult constant multiplier for offset values (such as e.g. `dim`)
 * @param stream
 */
template <typename T, typename IdxT>
void block_copy(const IdxT* in_offsets,
                const IdxT* out_offsets,
                IdxT n_blocks,
                const T* in_data,
                T* out_data,
                IdxT n_mult,
                rmm::cuda_stream_view stream)
{
  IdxT in_size;
  update_host(&in_size, in_offsets + n_blocks, 1, stream);
  stream.synchronize();
  dim3 threads(128, 1, 1);
  dim3 blocks(ceildiv<IdxT>(in_size * n_mult, threads.x), 1, 1);
  block_copy_kernel<<<blocks, threads, 0, stream>>>(
    in_offsets, out_offsets, n_blocks, in_data, out_data, n_mult);
}

/**
 * @brief Fill matrix `c` with all combinations of sums of vectors `a` and `b`.
 *
 * NB: device-only function
 *
 * @tparam T    element type
 * @tparam IdxT index type
 *
 * @param[in] a device pointer to a vector [len_a]
 * @param len_a number of elements in `a`
 * @param[in] b device pointer to a vector [len_b]
 * @param len_b number of elements in `b`
 * @param[out] c row-major matrix [len_a, len_b]
 * @param stream
 */
template <typename T, typename IdxT>
void outer_add(const T* a, IdxT len_a, const T* b, IdxT len_b, T* c, rmm::cuda_stream_view stream)
{
  dim3 threads(128, 1, 1);
  dim3 blocks(ceildiv<IdxT>(len_a * len_b, threads.x), 1, 1);
  outer_add_kernel<<<blocks, threads, 0, stream>>>(a, len_a, b, len_b, c);
}

template <typename T, typename S, typename IdxT, typename LabelT>
__global__ void copy_selected_kernel(
  IdxT n_rows, IdxT n_cols, const S* src, const LabelT* row_ids, IdxT ld_src, T* dst, IdxT ld_dst)
{
  IdxT gid   = threadIdx.x + blockDim.x * static_cast<IdxT>(blockIdx.x);
  IdxT j     = gid % n_cols;
  IdxT i_dst = gid / n_cols;
  if (i_dst >= n_rows) return;
  auto i_src              = static_cast<IdxT>(row_ids[i_dst]);
  dst[ld_dst * i_dst + j] = mapping<T>{}(src[ld_src * i_src + j]);
}

/**
 * @brief Copy selected rows of a matrix while mapping the data from the source to the target
 * type.
 *
 * @tparam T      target type
 * @tparam S      source type
 * @tparam IdxT   index type
 * @tparam LabelT label type
 *
 * @param n_rows
 * @param n_cols
 * @param[in] src input matrix [..., ld_src]
 * @param[in] row_ids selection of rows to be copied [n_rows]
 * @param ld_src number of cols in the input (ld_src >= n_cols)
 * @param[out] dst output matrix [n_rows, ld_dst]
 * @param ld_dst number of cols in the output (ld_dst >= n_cols)
 * @param stream
 */
template <typename T, typename S, typename IdxT, typename LabelT>
void copy_selected(IdxT n_rows,
                   IdxT n_cols,
                   const S* src,
                   const LabelT* row_ids,
                   IdxT ld_src,
                   T* dst,
                   IdxT ld_dst,
                   rmm::cuda_stream_view stream)
{
  switch (check_pointer_residency(src, dst, row_ids)) {
    case pointer_residency::host_and_device:
    case pointer_residency::device_only: {
      IdxT block_dim = 128;
      IdxT grid_dim  = ceildiv(n_rows * n_cols, block_dim);
      copy_selected_kernel<T, S>
        <<<grid_dim, block_dim, 0, stream>>>(n_rows, n_cols, src, row_ids, ld_src, dst, ld_dst);
    } break;
    case pointer_residency::host_only: {
      stream.synchronize();
      for (IdxT i_dst = 0; i_dst < n_rows; i_dst++) {
        auto i_src = static_cast<IdxT>(row_ids[i_dst]);
        for (IdxT j = 0; j < n_cols; j++) {
          dst[ld_dst * i_dst + j] = mapping<T>{}(src[ld_src * i_src + j]);
        }
      }
      stream.synchronize();
    } break;
    default: RAFT_FAIL("All pointers must reside on the same side, host or device.");
  }
}

}  // namespace raft::spatial::knn::detail::utils
