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

#include "../test_utils.h"
#include "ann_utils.cuh"

#include <raft/core/device_mdspan.hpp>
#include <raft/core/logger.hpp>
#include <raft/distance/distance_types.hpp>
#include <raft/random/rng.cuh>
#include <raft/spatial/knn/ann.cuh>
#include <raft/spatial/knn/ivf_flat.cuh>
#include <raft/spatial/knn/knn.cuh>

#include <rmm/cuda_stream_view.hpp>
#include <rmm/device_buffer.hpp>

#include <gtest/gtest.h>

#include <thrust/sequence.h>

#if defined RAFT_DISTANCE_COMPILED && defined RAFT_NN_COMPILED
#include <raft/cluster/specializations.cuh>
#endif

#include <cstddef>
#include <iostream>
#include <vector>

namespace raft {
namespace spatial {
namespace knn {

template <typename IdxT>
struct AnnIvfFlatInputs {
  IdxT num_queries;
  IdxT num_db_vecs;
  IdxT dim;
  IdxT k;
  IdxT nprobe;
  IdxT nlist;
  raft::distance::DistanceType metric;
};

template <typename T, typename DataT, typename IdxT>
class AnnIVFFlatTest : public ::testing::TestWithParam<AnnIvfFlatInputs<IdxT>> {
 public:
  AnnIVFFlatTest()
    : stream_(handle_.get_stream()),
      ps(::testing::TestWithParam<AnnIvfFlatInputs<IdxT>>::GetParam()),
      database(0, stream_),
      search_queries(0, stream_)
  {
  }

 protected:
  void testIVFFlat()
  {
    size_t queries_size = ps.num_queries * ps.k;
    std::vector<IdxT> indices_ivfflat(queries_size);
    std::vector<IdxT> indices_naive(queries_size);
    std::vector<T> distances_ivfflat(queries_size);
    std::vector<T> distances_naive(queries_size);

    {
      rmm::device_uvector<T> distances_naive_dev(queries_size, stream_);
      rmm::device_uvector<IdxT> indices_naive_dev(queries_size, stream_);
      naiveBfKnn<T, DataT, IdxT>(distances_naive_dev.data(),
                                 indices_naive_dev.data(),
                                 search_queries.data(),
                                 database.data(),
                                 ps.num_queries,
                                 ps.num_db_vecs,
                                 ps.dim,
                                 ps.k,
                                 ps.metric,
                                 stream_);
      update_host(distances_naive.data(), distances_naive_dev.data(), queries_size, stream_);
      update_host(indices_naive.data(), indices_naive_dev.data(), queries_size, stream_);
      handle_.sync_stream(stream_);
    }

    {
      // unless something is really wrong with clustering, this could serve as a lower bound on
      // recall
      double min_recall = static_cast<double>(ps.nprobe) / static_cast<double>(ps.nlist);

      rmm::device_uvector<T> distances_ivfflat_dev(queries_size, stream_);
      rmm::device_uvector<IdxT> indices_ivfflat_dev(queries_size, stream_);

      {
        // legacy interface
        raft::spatial::knn::IVFFlatParam ivfParams;
        ivfParams.nprobe = ps.nprobe;
        ivfParams.nlist  = ps.nlist;
        raft::spatial::knn::knnIndex index;
        index.index   = nullptr;
        index.gpu_res = nullptr;

        approx_knn_build_index(handle_,
                               &index,
                               dynamic_cast<raft::spatial::knn::knnIndexParam*>(&ivfParams),
                               ps.metric,
                               (IdxT)0,
                               database.data(),
                               ps.num_db_vecs,
                               ps.dim);
        handle_.sync_stream(stream_);
        approx_knn_search(handle_,
                          distances_ivfflat_dev.data(),
                          indices_ivfflat_dev.data(),
                          &index,
                          ps.k,
                          search_queries.data(),
                          ps.num_queries);

        update_host(distances_ivfflat.data(), distances_ivfflat_dev.data(), queries_size, stream_);
        update_host(indices_ivfflat.data(), indices_ivfflat_dev.data(), queries_size, stream_);
        handle_.sync_stream(stream_);
      }

      ASSERT_TRUE(eval_neighbours(indices_naive,
                                  indices_ivfflat,
                                  distances_naive,
                                  distances_ivfflat,
                                  ps.num_queries,
                                  ps.k,
                                  0.001,
                                  min_recall));
      {
        // new interface
        raft::spatial::knn::ivf_flat::index_params index_params;
        raft::spatial::knn::ivf_flat::search_params search_params;
        index_params.n_lists   = ps.nlist;
        index_params.metric    = ps.metric;
        search_params.n_probes = ps.nprobe;

        index_params.add_data_on_build        = false;
        index_params.kmeans_trainset_fraction = 0.5;

        auto database_view = raft::make_device_matrix_view<const DataT, IdxT>(
          (const DataT*)database.data(), ps.num_db_vecs, ps.dim);

        auto index = ivf_flat::build_index(handle_, database_view, index_params);

        rmm::device_uvector<IdxT> vector_indices(ps.num_db_vecs, stream_);
        thrust::sequence(handle_.get_thrust_policy(),
                         thrust::device_pointer_cast(vector_indices.data()),
                         thrust::device_pointer_cast(vector_indices.data() + ps.num_db_vecs));
        handle_.sync_stream(stream_);

        IdxT half_of_data = ps.num_db_vecs / 2;

        auto half_of_data_view = raft::make_device_matrix_view<const DataT, IdxT>(
          (const DataT*)database.data(), half_of_data, ps.dim);

        auto index_2 = ivf_flat::extend(handle_, index, half_of_data_view);

        ivf_flat::extend(handle_,
                         &index_2,
                         database.data() + half_of_data * ps.dim,
                         vector_indices.data() + half_of_data,
                         IdxT(ps.num_db_vecs) - half_of_data);

        ivf_flat::search(handle_,
                         search_params,
                         index_2,
                         search_queries.data(),
                         ps.num_queries,
                         ps.k,
                         indices_ivfflat_dev.data(),
                         distances_ivfflat_dev.data());

        update_host(distances_ivfflat.data(), distances_ivfflat_dev.data(), queries_size, stream_);
        update_host(indices_ivfflat.data(), indices_ivfflat_dev.data(), queries_size, stream_);
        handle_.sync_stream(stream_);
      }
      ASSERT_TRUE(eval_neighbours(indices_naive,
                                  indices_ivfflat,
                                  distances_naive,
                                  distances_ivfflat,
                                  ps.num_queries,
                                  ps.k,
                                  0.001,
                                  min_recall));
    }
  }

  void SetUp() override
  {
    database.resize(ps.num_db_vecs * ps.dim, stream_);
    search_queries.resize(ps.num_queries * ps.dim, stream_);

    raft::random::Rng r(1234ULL);
    if constexpr (std::is_same<DataT, float>{}) {
      r.uniform(database.data(), ps.num_db_vecs * ps.dim, DataT(0.1), DataT(2.0), stream_);
      r.uniform(search_queries.data(), ps.num_queries * ps.dim, DataT(0.1), DataT(2.0), stream_);
    } else {
      r.uniformInt(database.data(), ps.num_db_vecs * ps.dim, DataT(1), DataT(20), stream_);
      r.uniformInt(search_queries.data(), ps.num_queries * ps.dim, DataT(1), DataT(20), stream_);
    }
    handle_.sync_stream(stream_);
  }

  void TearDown() override
  {
    handle_.sync_stream(stream_);
    database.resize(0, stream_);
    search_queries.resize(0, stream_);
  }

 private:
  raft::handle_t handle_;
  rmm::cuda_stream_view stream_;
  AnnIvfFlatInputs<IdxT> ps;
  rmm::device_uvector<DataT> database;
  rmm::device_uvector<DataT> search_queries;
};

const std::vector<AnnIvfFlatInputs<int64_t>> inputs = {
  // test various dims (aligned and not aligned to vector sizes)
  {1000, 10000, 1, 16, 40, 1024, raft::distance::DistanceType::L2Expanded},
  {1000, 10000, 2, 16, 40, 1024, raft::distance::DistanceType::L2Expanded},
  {1000, 10000, 3, 16, 40, 1024, raft::distance::DistanceType::L2Expanded},
  {1000, 10000, 4, 16, 40, 1024, raft::distance::DistanceType::L2Expanded},
  {1000, 10000, 5, 16, 40, 1024, raft::distance::DistanceType::InnerProduct},
  {1000, 10000, 8, 16, 40, 1024, raft::distance::DistanceType::InnerProduct},

  // test dims that do not fit into kernel shared memory limits
  {1000, 10000, 2048, 16, 40, 1024, raft::distance::DistanceType::L2Expanded},
  {1000, 10000, 2049, 16, 40, 1024, raft::distance::DistanceType::L2Expanded},
  {1000, 10000, 2050, 16, 40, 1024, raft::distance::DistanceType::InnerProduct},
  {1000, 10000, 2051, 16, 40, 1024, raft::distance::DistanceType::InnerProduct},
  {1000, 10000, 2052, 16, 40, 1024, raft::distance::DistanceType::InnerProduct},
  {1000, 10000, 2053, 16, 40, 1024, raft::distance::DistanceType::L2Expanded},
  {1000, 10000, 2056, 16, 40, 1024, raft::distance::DistanceType::L2Expanded},

  // various random combinations
  {1000, 10000, 16, 10, 40, 1024, raft::distance::DistanceType::L2Expanded},
  {1000, 10000, 16, 10, 50, 1024, raft::distance::DistanceType::L2Expanded},
  {1000, 10000, 16, 10, 70, 1024, raft::distance::DistanceType::L2Expanded},
  {100, 10000, 16, 10, 20, 512, raft::distance::DistanceType::L2Expanded},
  {20, 100000, 16, 10, 20, 1024, raft::distance::DistanceType::L2Expanded},
  {1000, 100000, 16, 10, 20, 1024, raft::distance::DistanceType::L2Expanded},
  {10000, 131072, 8, 10, 20, 1024, raft::distance::DistanceType::L2Expanded},

  {1000, 10000, 16, 10, 40, 1024, raft::distance::DistanceType::InnerProduct},
  {1000, 10000, 16, 10, 50, 1024, raft::distance::DistanceType::InnerProduct},
  {1000, 10000, 16, 10, 70, 1024, raft::distance::DistanceType::InnerProduct},
  {100, 10000, 16, 10, 20, 512, raft::distance::DistanceType::InnerProduct},
  {20, 100000, 16, 10, 20, 1024, raft::distance::DistanceType::InnerProduct},
  {1000, 100000, 16, 10, 20, 1024, raft::distance::DistanceType::InnerProduct},
  {10000, 131072, 8, 10, 50, 1024, raft::distance::DistanceType::InnerProduct},

  {1000, 10000, 4096, 20, 50, 1024, raft::distance::DistanceType::InnerProduct},

  // test splitting the big query batches  (> max gridDim.y) into smaller batches
  {100000, 1024, 32, 10, 64, 64, raft::distance::DistanceType::InnerProduct},
  {98306, 1024, 32, 10, 64, 64, raft::distance::DistanceType::InnerProduct},

  // test radix_sort for getting the cluster selection
  {1000,
   10000,
   16,
   10,
   raft::spatial::knn::detail::topk::kMaxCapacity * 2,
   raft::spatial::knn::detail::topk::kMaxCapacity * 4,
   raft::distance::DistanceType::L2Expanded},
  {1000,
   10000,
   16,
   10,
   raft::spatial::knn::detail::topk::kMaxCapacity * 4,
   raft::spatial::knn::detail::topk::kMaxCapacity * 4,
   raft::distance::DistanceType::InnerProduct}};

typedef AnnIVFFlatTest<float, float, std::int64_t> AnnIVFFlatTestF;
TEST_P(AnnIVFFlatTestF, AnnIVFFlat) { this->testIVFFlat(); }

INSTANTIATE_TEST_CASE_P(AnnIVFFlatTest, AnnIVFFlatTestF, ::testing::ValuesIn(inputs));

typedef AnnIVFFlatTest<float, uint8_t, std::int64_t> AnnIVFFlatTestF_uint8;
TEST_P(AnnIVFFlatTestF_uint8, AnnIVFFlat) { this->testIVFFlat(); }

INSTANTIATE_TEST_CASE_P(AnnIVFFlatTest, AnnIVFFlatTestF_uint8, ::testing::ValuesIn(inputs));

typedef AnnIVFFlatTest<float, int8_t, std::int64_t> AnnIVFFlatTestF_int8;
TEST_P(AnnIVFFlatTestF_int8, AnnIVFFlat) { this->testIVFFlat(); }

INSTANTIATE_TEST_CASE_P(AnnIVFFlatTest, AnnIVFFlatTestF_int8, ::testing::ValuesIn(inputs));

}  // namespace knn
}  // namespace spatial
}  // namespace raft
