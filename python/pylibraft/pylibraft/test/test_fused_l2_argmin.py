# Copyright (c) 2022, NVIDIA CORPORATION.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
#

from scipy.spatial.distance import cdist
import pytest
import numpy as np

from pylibraft.distance import fused_l2_nn_argmin
from pylibraft.testing.utils import TestDeviceBuffer


@pytest.mark.parametrize("n_rows", [10, 100])
@pytest.mark.parametrize("n_clusters", [5, 10])
@pytest.mark.parametrize("n_cols", [3, 5])
@pytest.mark.parametrize("dtype", [np.float32, np.float64])
def test_fused_l2_nn_minarg(n_rows, n_cols, n_clusters, dtype):
    input1 = np.random.random_sample((n_rows, n_cols))
    input1 = np.asarray(input1, order="C").astype(dtype)

    input2 = np.random.random_sample((n_clusters, n_cols))
    input2 = np.asarray(input2, order="C").astype(dtype)

    output = np.zeros((n_rows), dtype="int32")
    expected = cdist(input1, input2, metric="euclidean")

    expected = expected.argmin(axis=1)

    input1_device = TestDeviceBuffer(input1, "C")
    input2_device = TestDeviceBuffer(input2, "C")
    output_device = TestDeviceBuffer(output, "C")

    fused_l2_nn_argmin(input1_device, input2_device, output_device, True)
    actual = output_device.copy_to_host()

    assert np.allclose(expected, actual, rtol=1e-4)
