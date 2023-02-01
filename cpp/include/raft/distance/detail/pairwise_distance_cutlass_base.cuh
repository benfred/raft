/*
 * Copyright (c) 2018-2023, NVIDIA CORPORATION.
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

#pragma GCC diagnostic push
#pragma GCC diagnostic ignored "-Wstrict-aliasing"

#if (__CUDACC_VER_MAJOR__ < 12)

// We define CUTLASS_NAMESPACE in case
// RAFT cmake is not used
#ifndef CUTLASS_NAMESPACE
#define cutlass raft_cutlass
#endif

#include <rmm/device_uvector.hpp>

#include <cutlass/cutlass.h>
#include <cutlass/gemm/device/gemm.h>
#include <cutlass/gemm/device/gemm_universal_adapter.h>

#include <cutlass/layout/matrix.h>
#include <cutlass/layout/tensor.h>
#include <cutlass/matrix_coord.h>
#include <cutlass/tensor_view.h>

#include "./pairwise_distance_epilogue_elementwise.h"
#include "./pairwise_distance_gemm.h"

#define CUTLASS_CHECK(status)                                                                    \
  {                                                                                              \
    cutlass::Status error = status;                                                              \
    if (error != cutlass::Status::kSuccess) {                                                    \
      std::cerr << "Got cutlass error: " << cutlassGetStatusString(error) << " at: " << __LINE__ \
                << std::endl;                                                                    \
      exit(EXIT_FAILURE);                                                                        \
    }                                                                                            \
  }

namespace raft {
namespace distance {
namespace detail {

template <typename DataT,
          typename AccT,
          typename OutT,
          typename IdxT,
          int VecLen,
          typename FinalLambda,
          typename DistanceFn,
          bool isRowMajor>
void cutlassDistanceKernel(const DataT* x,
                           const DataT* y,
                           const DataT* xn,
                           const DataT* yn,
                           IdxT m,
                           IdxT n,
                           IdxT k,
                           IdxT lda,
                           IdxT ldb,
                           IdxT ldd,
                           OutT* dOutput,
                           FinalLambda fin_op,
                           DistanceFn dist_op,
                           cudaStream_t stream)
{
  static_assert(!(std::is_same<OutT, bool>::value),
                "OutType bool is not supported use uint8_t instead");

  using EpilogueOutputOp =
    cutlass::epilogue::thread::PairwiseDistanceEpilogueElementwise<DataT,  // ElementC_
                                                                   AccT,   // ElementAccumulator_
                                                                   DataT,  // ElementCompute_
                                                                   AccT,   // ElementZ_
                                                                   OutT,   // ElementT_
                                                                   1,      // Elements per access 1
                                                                   DistanceFn,
                                                                   FinalLambda>;
  constexpr int batch_count = 1;

  constexpr auto mode = cutlass::gemm::GemmUniversalMode::kGemm;

  typename EpilogueOutputOp::Params epilog_op_param(dist_op, fin_op);

  const DataT *a, *b;

  IdxT gemm_lda, gemm_ldb;

  // Number of pipelines you want to use
  constexpr int NumStages = 3;
  // Alignment
  constexpr int Alignment = VecLen;

  // default initialize problem size with row major inputs
  auto problem_size = cutlass::gemm::GemmCoord(n, m, k);

  using cutlassDistKernel =
    typename cutlass::gemm::kernel::PairwiseDistanceGemm<DataT,
                                                         Alignment,
                                                         DataT,
                                                         Alignment,
                                                         AccT,
                                                         AccT,
                                                         EpilogueOutputOp,
                                                         NumStages,  // Number of pipeline stages
                                                         isRowMajor>::GemmKernel;

  using cutlassDist = cutlass::gemm::device::GemmUniversalAdapter<cutlassDistKernel>;

  if constexpr (isRowMajor) {
    a        = y;
    b        = x;
    gemm_lda = ldb;
    gemm_ldb = lda;
  } else {
    problem_size = cutlass::gemm::GemmCoord(m, n, k);
    a            = x;
    b            = y;
    gemm_lda     = lda;
    gemm_ldb     = ldb;
  }

  typename cutlassDist::Arguments arguments{
    mode,
    problem_size,
    batch_count,
    epilog_op_param,
    a,
    b,
    xn,          // C matrix eq vector param, which here is A norm
    nullptr,     // tensor_Z,
    (DataT*)yn,  // this is broadcast vec, which is required to be non-const param
    dOutput,     // Output distance matrix
    (int64_t)0,  // batch stride A
    (int64_t)0,  // batch stride B
    (int64_t)0,  // batch stride Norm A
    (int64_t)0,
    (int64_t)0,         // batch stride Norm B
    (int64_t)0,         // batch stride Output
    (int64_t)gemm_lda,  // stride A
    (int64_t)gemm_ldb,  // stride B
    1,                  // stride A norm
    0,                  // this is no-op for Z
    0,                  // This must be zero
    (int64_t)ldd        // stride Output matrix
  };

  // Using the arguments, query for extra workspace required for matrix multiplication computation
  size_t workspace_size = cutlassDist::get_workspace_size(arguments);
  // Allocate workspace memory
  rmm::device_uvector<uint8_t> workspace(workspace_size, stream);
  // Instantiate CUTLASS kernel depending on templates
  cutlassDist cutlassDist_op;
  // Check the problem size is supported or not
  cutlass::Status status = cutlassDist_op.can_implement(arguments);
  CUTLASS_CHECK(status);
  // Initialize CUTLASS kernel with arguments and workspace pointer
  status = cutlassDist_op.initialize(arguments, workspace.data(), stream);
  CUTLASS_CHECK(status);
  // Launch initialized CUTLASS kernel
  status = cutlassDist_op();
  CUTLASS_CHECK(status);
}

};      // namespace detail
};      // namespace distance
};      // namespace raft
#endif  //  (__CUDACC_VER_MAJOR__ < 12)
#pragma GCC diagnostic pop
