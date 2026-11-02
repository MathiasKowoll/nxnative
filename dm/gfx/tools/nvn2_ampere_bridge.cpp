// SPDX-FileCopyrightText: Copyright 2026 NXNative contributors
// SPDX-License-Identifier: GPL-3.0-or-later
//
// Optional offline adapter for Eglantine's GPL Ampere lowerer.  This source and
// any binary built from it remain outside the MIT runtime.  No Eglantine code
// or bridge binary is bundled in the application.

#include <array>
#include <cstdlib>
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <fstream>
#include <iterator>
#include <span>
#include <string>
#include <string_view>
#include <vector>

#include "shader_recompiler/frontend/ampere/program_capture.h"

namespace {
using Shader::Ampere::Instruction;

constexpr std::uint32_t Isberd = 0x923;
constexpr std::uint32_t Isbewr = 0x927;
constexpr std::uint32_t Sured = 0x59f;
constexpr std::uint32_t Upopc = 0x2bf;
constexpr std::uint64_t MaxwellNop = 0x50b0000000000f00ULL;

enum class Role { Task, Mesh, Fragment, Vertex, Compute };
enum class Space : std::uint32_t {
    TaskPayload = 0,
    MeshDispatchCount = 1,
    MeshPrimitiveCount = 2,
    MeshAttribute = 3,
    MeshIndex = 4,
    MeshGroupIndex = 5,
    TaskGroupIndex = 6,
};

struct Replacement {
    std::uint32_t source_index;
    std::uint64_t pseudo;
    std::uint64_t expected_opcode;
};

std::uint32_t Bits(const Instruction& instruction, std::uint32_t offset, std::uint32_t count) {
    return instruction.Bits(offset, count);
}

bool Classify(Role role, const Instruction& instruction, Space& space, const char*& error) {
    const std::uint32_t opcode = Bits(instruction, 0, 12);
    const bool write = opcode == Isbewr;
    const std::uint32_t offset_register = Bits(instruction, 24, 8);
    const std::uint32_t immediate = Bits(instruction, 40, 16);
    const std::uint32_t memory_type = Bits(instruction, 74, 2);
    const std::uint32_t access_type = Bits(instruction, 76, 2);
    const bool output = Bits(instruction, 79, 1) != 0;

    if (role == Role::Fragment || role == Role::Vertex || role == Role::Compute) {
        error = "ISBE is only supported by the task/mesh bridge";
        return false;
    }

    if (memory_type > 2) {
        error = "reserved ISBE memory width";
        return false;
    }
    if (role == Role::Task) {
        if (!write) {
            if (!output && access_type == 3 && memory_type == 2 &&
                offset_register == 255 && immediate == 0) {
                // Native task programs can read the hardware-provided mesh
                // workgroup index through the same reserved ISBE form as a
                // mesh program. It is not task payload.
                space = Space::TaskGroupIndex;
                return true;
            }
            error = "task ISBE read is not the reserved workgroup index";
            return false;
        }
        if (!output || access_type != 3) {
            error = "task ISBE is not an output attribute write";
            return false;
        }
        const bool dispatch = memory_type == 2 && offset_register == 255 &&
                              (immediate == 4 || immediate == 8 || immediate == 12 || immediate == 16);
        space = dispatch ? Space::MeshDispatchCount : Space::TaskPayload;
        return true;
    }

    if (!write) {
        if (output || access_type != 3) {
            error = "mesh ISBE read is not a task-payload attribute read";
            return false;
        }
        // The mesh shader's reserved RZ + 0 b32 read is the hardware-provided
        // mesh workgroup index.  It is not task payload and must become the
        // compute workgroup-id builtin in the translated kernel.
        const bool group_index = memory_type == 2 && offset_register == 255 && immediate == 0;
        space = group_index ? Space::MeshGroupIndex : Space::TaskPayload;
        return true;
    }
    if (!output) {
        error = "mesh ISBE write does not target output memory";
        return false;
    }
    if (access_type == 3) {
        space = Space::MeshAttribute;
        return true;
    }
    if (access_type == 0 && memory_type == 2 && immediate == 3) {
        space = Space::MeshPrimitiveCount;
        return true;
    }
    if (access_type == 0 && memory_type == 0 && immediate >= 4) {
        space = Space::MeshIndex;
        return true;
    }
    error = "unsupported mesh ISBE output domain";
    return false;
}

std::uint64_t EncodePseudo(const Instruction& instruction, Space space) {
    const bool write = Bits(instruction, 0, 12) == Isbewr;
    const std::uint64_t opcode = write ? 0x1fffULL : 0x1ffeULL;
    const std::uint64_t value_register = write ? Bits(instruction, 32, 8) : Bits(instruction, 16, 8);
    std::uint64_t result = opcode << 51;
    if (write) {
        result |= value_register << 20;
    } else {
        result |= value_register;
    }
    result |= std::uint64_t{Bits(instruction, 24, 8)} << 8;
    result |= std::uint64_t{Bits(instruction, 12, 4)} << 16;
    result |= std::uint64_t{Bits(instruction, 40, 16)} << 28;
    result |= static_cast<std::uint64_t>(space) << 44;
    result |= std::uint64_t{Bits(instruction, 74, 2)} << 47;
    result |= std::uint64_t{Bits(instruction, 78, 1)} << 49;
    return result;
}

std::uint32_t UniformRegister(std::uint32_t reg) {
    if (reg < 22) return 216 + reg;
    if (reg < 28) return 218 + reg;
    if (reg == 63) return 255;
    return ~0U;
}

bool RewriteUniformPopcount(Instruction& instruction, std::uint64_t& replacement,
                            const char*& error) {
    // SM80's UPOPC URd, URa uses the same population-count operation as the
    // lowerer's register form. Move URd into the reserved GPR uniform bank and
    // rewrite the instruction to the already-supported uniform-source POPC.
    // The observed SDK 201 form is unguarded and has no modifiers except the
    // source inversion bit at 63, which that POPC form preserves.
    const std::uint32_t destination = UniformRegister(Bits(instruction, 16, 6));
    const std::uint32_t source = UniformRegister(Bits(instruction, 32, 6));
    if (destination == ~0U || source == ~0U) {
        error = "UPOPC uniform register is outside the mapped bank";
        return false;
    }
    if (Bits(instruction, 12, 4) != 7 || Bits(instruction, 22, 10) ||
        Bits(instruction, 38, 25) || instruction.words[2] != 0x08000000U) {
        error = "unsupported UPOPC form";
        return false;
    }
    replacement = 0x5c08000000000000ULL | destination |
                  (std::uint64_t{source} << 20) |
                  (std::uint64_t{Bits(instruction, 63, 1)} << 40);
    // UMOV URd, URa is a one-instruction placeholder that makes the lowerer
    // reserve and map the uniform register bank. Replace its Maxwell MOV with
    // the POPC word above after branch relocation is complete.
    instruction.words[0] = (instruction.words[0] & 0x003ff000U) | 0xc82U;
    instruction.words[1] &= 0x3fU;
    return true;
}

bool RewriteSurfaceReduction(Instruction& instruction, std::uint64_t& replacement,
                             const char*& error) {
    // SM80 SURED.I and Maxwell SURED use the same register, dimension,
    // operation, size, clamp and direct-descriptor fields at different bit
    // positions. The downstream Maxwell frontend represents the integer
    // 32-bit forms exactly as Metal image atomics. Rewrite through a supported
    // SUST.I placeholder so Eglantine still validates the descriptor bank and
    // records it as the program's required texture buffer; replace the emitted
    // store only after branch relocation has finished.
    const std::uint32_t predicate = Bits(instruction, 12, 4);
    const std::uint32_t coordinate = Bits(instruction, 24, 8);
    const std::uint32_t operand = Bits(instruction, 32, 8);
    const std::uint32_t offset = Bits(instruction, 40, 14);
    const std::uint32_t binding = Bits(instruction, 54, 5);
    const std::uint32_t clamp = Bits(instruction, 59, 2);
    const std::uint32_t dimension = Bits(instruction, 61, 3);
    const std::uint32_t byte_address = Bits(instruction, 72, 1);
    const std::uint32_t size = Bits(instruction, 73, 3);
    const std::uint32_t memory = Bits(instruction, 77, 4);
    const std::uint32_t cache = Bits(instruction, 84, 3);
    const std::uint32_t operation = Bits(instruction, 87, 3);

    if (Bits(instruction, 91, 1) || Bits(instruction, 16, 8) ||
        Bits(instruction, 64, 8) || Bits(instruction, 76, 1) ||
        Bits(instruction, 81, 3) || Bits(instruction, 90, 1) ||
        Bits(instruction, 92, 13)) {
        error = "unsupported SURED descriptor form";
        return false;
    }
    if (dimension > 5 || clamp != 0 || byte_address != 0 ||
        (size != 0 && size != 1 && size != 6) || memory != 7 || cache != 1) {
        error = "unsupported SURED image mode";
        return false;
    }
    const std::uint32_t coordinate_count = dimension == 2 || dimension == 3 ? 2 :
                                           dimension >= 4 ? 3 : 1;
    const std::uint32_t alignment = coordinate_count == 3 ? 4 :
                                    coordinate_count == 2 ? 2 : 1;
    if (coordinate == 255 || coordinate > 255 - coordinate_count ||
        coordinate % alignment || operand == 254 || binding >= 18 || offset > 0x1fff) {
        error = "unsupported SURED register or descriptor range";
        return false;
    }

    replacement = 0xeb58000000000000ULL |
                  (std::uint64_t{predicate} << 16) |
                  operand | (std::uint64_t{coordinate} << 8) |
                  (std::uint64_t{size} << 20) |
                  (std::uint64_t{operation} << 24) |
                  (std::uint64_t{dimension} << 33) |
                  (std::uint64_t{offset} << 36);

    instruction = {};
    instruction.words[0] = 0xb9bU | (predicate << 12) | (coordinate << 24);
    instruction.words[1] = operand | (offset << 8) | (binding << 22) |
                           (dimension << 29);
    instruction.words[2] = 0x00100f00U;
    return true;
}

bool ParseUnsigned(std::string_view text, std::size_t& value) {
    char* end = nullptr;
    const std::string copy{text};
    const unsigned long long parsed = std::strtoull(copy.c_str(), &end, 0);
    if (!end || *end != '\0') return false;
    value = static_cast<std::size_t>(parsed);
    return true;
}
} // namespace

int main(int argc, char** argv) {
    if (argc < 4 || argc > 5) {
        std::fprintf(stderr, "usage: nvn2_ampere_bridge task|mesh|fragment|vertex|compute input.code output.bin [header-size]\n");
        return 2;
    }
    const std::string_view role_text{argv[1]};
    const Role role = role_text == "task" ? Role::Task :
                      role_text == "mesh" ? Role::Mesh :
                      role_text == "fragment" ? Role::Fragment :
                      role_text == "compute" ? Role::Compute : Role::Vertex;
    if (role_text != "task" && role_text != "mesh" &&
        role_text != "fragment" && role_text != "vertex" && role_text != "compute") {
        std::fprintf(stderr, "role must be task, mesh, fragment, vertex or compute\n");
        return 2;
    }
    // Native graphics programs begin after their 128-byte shader header.
    // Native compute code is addressed directly by the QMD and has no prefix;
    // Eglantine's ComputeEnvironment likewise calls InitializeNativeCode(0).
    std::size_t header_size = role == Role::Compute ? 0 : 0x80;
    if (argc == 5 && !ParseUnsigned(argv[4], header_size)) {
        std::fprintf(stderr, "invalid header size\n");
        return 2;
    }

    std::ifstream input(argv[2], std::ios::binary);
    std::vector<std::uint8_t> bytes((std::istreambuf_iterator<char>(input)), {});
    if (input.bad() || header_size > bytes.size() || header_size % 16 ||
        (bytes.size() - header_size) % sizeof(Instruction)) {
        std::fprintf(stderr, "input does not contain an aligned native instruction span\n");
        return 2;
    }

    const std::size_t available = (bytes.size() - header_size) / sizeof(Instruction);
    if (available == 0 || available > Shader::Ampere::ProgramCaptureState::MaximumInstructions) {
        std::fprintf(stderr, "native instruction span is outside the capture bound\n");
        return 2;
    }
    std::vector<Instruction> source(available);
    std::memcpy(source.data(), bytes.data() + header_size, available * sizeof(Instruction));
    Shader::Ampere::ProgramCaptureState capture;
    std::size_t count = 0;
    bool complete = false;
    for (; count < source.size(); ++count) {
        const auto state = capture.Observe(source[count], static_cast<std::uint32_t>(count));
        if (state == Shader::Ampere::ProgramCaptureState::Result::InvalidTarget) {
            std::fprintf(stderr, "capture rejected branch target at source instruction %zu\n", count);
            return 1;
        }
        if (state == Shader::Ampere::ProgramCaptureState::Result::Complete) {
            ++count;
            complete = true;
            break;
        }
    }
    // A compact control gives us the exact native code span. ProgramCaptureState
    // can conservatively miss a valid end when CALL.REL.NOINC contributes a
    // forward target beyond the main EXIT; Eglantine's live environment also
    // reaches the mapping boundary and lets LowerToMaxwell judge that bounded
    // program. Keep the complete span in that case so its linkage checks make
    // the decision instead of accepting it here.
    if (!complete) count = source.size();
    source.resize(count);

    std::vector<Replacement> replacements;
    for (std::uint32_t index = 0; index < source.size(); ++index) {
        const std::uint32_t opcode = Bits(source[index], 0, 12);
        if (opcode == Upopc) {
            const char* error = nullptr;
            std::uint64_t replacement = 0;
            if (!RewriteUniformPopcount(source[index], replacement, error)) {
                std::fprintf(stderr, "source instruction %u: %s\n", index, error);
                return 1;
            }
            replacements.push_back({index, replacement, 0x5c9});
            continue;
        }
        if (opcode == Sured) {
            if (role != Role::Compute) {
                std::fprintf(stderr, "source instruction %u: SURED is only validated for compute\n", index);
                return 1;
            }
            const char* error = nullptr;
            std::uint64_t replacement = 0;
            if (!RewriteSurfaceReduction(source[index], replacement, error)) {
                std::fprintf(stderr, "source instruction %u: %s\n", index, error);
                return 1;
            }
            replacements.push_back({index, replacement, 0xeb2});
            continue;
        }
        if (opcode != Isberd && opcode != Isbewr) continue;
        Space space{};
        const char* error = nullptr;
        if (!Classify(role, source[index], space, error)) {
            std::fprintf(stderr, "source instruction %u: %s\n", index, error);
            return 1;
        }
        // @!PT is compiler padding and the lowerer intentionally emits nothing.
        if (Bits(source[index], 12, 4) != 15) {
            replacements.push_back({index, EncodePseudo(source[index], space), MaxwellNop >> 52});
        }
        const std::uint32_t predicate = Bits(source[index], 12, 4);
        source[index] = {};
        source[index].words[0] = 0x918 | (predicate << 12);
    }

    auto lowered = Shader::Ampere::LowerToMaxwell(source);
    if (!lowered) {
        std::fprintf(stderr, "lowering failed at source byte %#x: %.*s\n", lowered.error_offset,
                     static_cast<int>(lowered.error.size()), lowered.error.data());
        return 1;
    }
    for (const Replacement replacement : replacements) {
        const std::size_t output_index = lowered.source_instruction_offsets[replacement.source_index];
        if (output_index >= lowered.instructions.size() ||
            (lowered.instructions[output_index] >> 52) != replacement.expected_opcode) {
            std::fprintf(stderr, "source instruction %u did not lower to the expected replaceable instruction\n",
                         replacement.source_index);
            return 1;
        }
        lowered.instructions[output_index] = replacement.pseudo;
    }

    // Graphics stages retain the native header's Maxwell-compatible 0x50-byte
    // SPH. Ryujinx numbers graphics instructions from zero after that header,
    // so every output uses a control word and one leading NOP before the
    // lowered program. Relative branches remain exact and compute/task/mesh
    // use the same instruction-address phase when translated as kernels.
    const bool graphics = role == Role::Fragment || role == Role::Vertex;
    std::vector<std::uint64_t> scheduled;
    if (graphics) {
        scheduled.resize(0x50 / sizeof(std::uint64_t));
        std::memcpy(scheduled.data(), bytes.data(), 0x50);
    }
    const std::size_t header_bytes = scheduled.size() * sizeof(std::uint64_t);
    scheduled.push_back(0);
    scheduled.push_back(MaxwellNop);
    for (const std::uint64_t instruction : lowered.instructions) {
        if ((scheduled.size() * sizeof(std::uint64_t) - header_bytes) % 32 == 0) scheduled.push_back(0);
        scheduled.push_back(instruction);
    }
    std::ofstream output(argv[3], std::ios::binary | std::ios::trunc);
    output.write(reinterpret_cast<const char*>(scheduled.data()),
                 static_cast<std::streamsize>(scheduled.size() * sizeof(std::uint64_t)));
    if (!output) {
        std::fprintf(stderr, "failed to write output\n");
        return 1;
    }
    const std::string texture_buffer = lowered.required_texture_buffer == ~0U
                                           ? "none"
                                           : std::to_string(lowered.required_texture_buffer);
    std::printf("role=%.*s captured=%zu maxwell=%zu isbe=%zu scheduled-bytes=%zu texture-buffer=%s\n",
                static_cast<int>(role_text.size()), role_text.data(), source.size(),
                lowered.instructions.size(), replacements.size(),
                scheduled.size() * sizeof(std::uint64_t), texture_buffer.c_str());
    return 0;
}
