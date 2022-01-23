# Owner(s): ["oncall: jit"]

from torch.testing._internal.jit_utils import JitTestCase
import torch
import torch._C
from torch.testing import FileCheck
from typing import Callable

class FunctionalLinear(torch.nn.Module):
    def __init__(self, weight: torch.Tensor, bias: torch.Tensor = None):
        super(FunctionalLinear, self).__init__()
        self.weight = weight
        self.bias = bias

    def forward(self, x: torch.Tensor):
        res = torch.matmul(x, self.weight.t())
        if self.bias is not None:
            res.add_(self.bias)
        return res

class FunctionalConv2d(torch.nn.Module):
    def __init__(self, in_channels: int, out_channels: int, kernel_size: int):
        super(FunctionalConv2d, self).__init__()
        self.conv2d = torch.nn.Conv2d(int_channels, out_channels, kernel_size)

    def forward(self, x: torch.Tensor):
        return self.conv2d(x)

class Matmul(torch.nn.Module):
    def __init__(self, weight: torch.Tensor):
        super(Matmul, self).__init__()
        self.weight = weight

    def forward(self, x: torch.Tensor):
        return torch.matmul(x, self.weight)

class TestGraphRewritePasses(JitTestCase):
    def check_rewrite(
        self,
        old_kind: str,
        new_kind: str,
        check_not: list[str],
        jit_pass: Callable[[str], None],
        model: torch.jit.ScriptModule
    ):
        for node in model.graph.nodes():
            if node.kind() == old_kind:
                source_range_1 = node.sourceRange()
        jit_pass(model.graph)
        for node in model.graph.nodes():
            if node.kind() == new_kind:
                source_range_2 = node.sourceRange()
        FileCheck().check(new_kind).run(model.graph)
        for cn in check_not:
            FileCheck().check_not(cn).run(model.graph)
        self.assertTrue(source_range_1 == source_range_2)

    def test_fuse_linear(self):
        x1 = torch.rand(3)
        w1 = torch.rand(5, 3)
        b1 = torch.rand(5)
        model1 = torch.jit.trace(FunctionalLinear(w1, b1), [x1])
        check_not = ["aten::matmul", "aten::addmm", "aten::add_", "aten::t("]
        self.check_rewrite("aten::matmul", "aten::linear", check_not, torch._C._jit_pass_fuse_linear, model1)
        model1(x1)  # make sure it runs

        model2 = torch.jit.trace(FunctionalLinear(w1, None), [x1])
        self.check_rewrite("aten::matmul", "aten::linear", check_not, torch._C._jit_pass_fuse_linear, model2)
        model2(x1)  # make sure it runs

        # check matmuls are not fused
        x3 = torch.rand(5, 6, 5)
        w3 = torch.rand(5, 5, 100)
        model3 = torch.jit.trace(Matmul(w3), [x3])
        check_not3 = ["aten::linear"]
        self.check_rewrite("aten::matmul", "aten::matmul", check_not3, torch._C._jit_pass_fuse_linear, model3)
        model3(x3)  # make sure it runs

    def test_vulkan_insert_pre_packed_ops(self):
        x1 = torch.rand(3)
        w1 = torch.rand(5, 3)
        b1 = torch.rand(5)
        model1 = torch.jit.trace(FunctionalLinear(w1, b1), [x1])
        check_not = ["aten::matmul", "aten::add_", "aten::t"]
        self.check_rewrite("aten::matmul", "vulkan_prepack::linear_run", check_not, torch._C._jit_pass_vulkan_insert_prepacked_ops, model1)
        model1(x1)
