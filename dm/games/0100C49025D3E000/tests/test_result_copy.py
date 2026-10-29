"""Execute the actual AArch64 cuts: Q0's high half must never come from Q1."""
import importlib.util
from pathlib import Path
import unittest
from unicorn import Uc, UC_ARCH_ARM64, UC_MODE_ARM, UC_HOOK_CODE
from unicorn.arm64_const import UC_ARM64_REG_X0, UC_ARM64_REG_X20, UC_ARM64_REG_X24, UC_ARM64_REG_Q1

spec = importlib.util.spec_from_file_location('fc27_patches', Path(__file__).resolve().parents[1] / 'patches.py')
patches = importlib.util.module_from_spec(spec)
spec.loader.exec_module(patches)
BUILD = 'fb81983aa1cc3a2e97402497e2ca6528'


class ResultCopy(unittest.TestCase):
    def run_copy(self, wrapper=True, result=True, job=True):
        uc = Uc(UC_ARCH_ARM64, UC_MODE_ARM)
        for address in (0x804e000, 0xe1fd000, 0x7c29000, 0x10000):
            uc.mem_map(address, 0x1000)
        for address, _, replacement, _ in patches.CUTS[BUILD]:
            uc.mem_write(address, bytes.fromhex(replacement))
        for address, code, _ in patches.CODE[BUILD]:
            uc.mem_write(address, bytes.fromhex(code))
        uc.mem_write(0x7c291a0, bytes.fromhex('c0035fd6'))  # release stub: RET
        payload = bytes.fromhex('887766554433221100ffeeddccbbaa997856341200000000')
        uc.mem_write(0x10400, payload)
        uc.mem_write(0x10600, (0x10400 if result else 0).to_bytes(8, 'little'))
        uc.mem_write(0x10118, b'\xa5' * 24)
        uc.reg_write(UC_ARM64_REG_X20, 0x10000)
        uc.reg_write(UC_ARM64_REG_X24, 0x10600 if wrapper else 0)
        uc.reg_write(UC_ARM64_REG_X0, 0x10800 if job else 0)
        uc.reg_write(UC_ARM64_REG_Q1, 0x3de35a683de35a68)  # unrelated SIMD data seen in crashes
        released = []
        def observe(cpu, address, size, unused):
            if address == 0x7c291a0:
                released.append(cpu.reg_read(UC_ARM64_REG_X0))
        uc.hook_add(UC_HOOK_CODE, observe)
        uc.emu_start(0x804e358, 0x804e374, count=40)
        self.assertEqual(bytes(uc.mem_read(0x10118, 24)), payload if wrapper and result else b'\xa5' * 24)
        self.assertEqual(released, [0x10800] if job else [])

    def test_original_128_bit_copy(self):
        self.run_copy()

    def test_empty_wrapper(self):
        self.run_copy(wrapper=False)

    def test_empty_result(self):
        self.run_copy(result=False)

    def test_missing_cleanup_job(self):
        self.run_copy(job=False)

    def test_empty_result_and_job(self):
        self.run_copy(result=False, job=False)
