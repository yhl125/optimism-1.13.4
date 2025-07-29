// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

// Libraries
import { MIPS64Memory } from "src/cannon/libraries/MIPS64Memory.sol";
import { MIPS64State as st } from "src/cannon/libraries/MIPS64State.sol";
import { MIPS64Arch as arch } from "src/cannon/libraries/MIPS64Arch.sol";

library MIPS64Instructions {
    uint32 internal constant OP_LOAD_LINKED = 0x30;
    uint32 internal constant OP_STORE_CONDITIONAL = 0x38;
    uint32 internal constant OP_LOAD_LINKED64 = 0x34;
    uint32 internal constant OP_STORE_CONDITIONAL64 = 0x3C;
    uint32 internal constant OP_LOAD_DOUBLE_LEFT = 0x1A;
    uint32 internal constant OP_LOAD_DOUBLE_RIGHT = 0x1B;
    uint32 internal constant REG_RA = 31;
    uint64 internal constant U64_MASK = 0xFFFFFFFFFFFFFFFF;
    uint32 internal constant U32_MASK = 0xFFffFFff;

    error InvalidPC();

    struct CoreStepLogicParams {
        /// @param opcode The opcode value parsed from insn.
        st.CpuScalars cpu;
        /// @param registers The CPU registers.
        uint64[32] registers;
        /// @param memRoot The current merkle root of the memory.
        bytes32 memRoot;
        /// @param memProofOffset The offset in calldata specify where the memory merkle proof is located.
        uint256 memProofOffset;
        /// @param insn The current MIPS instruction at the pc.
        uint32 insn;
        /// @param cpu The CPU scalar fields.
        uint32 opcode;
        /// @param fun The function value parsed from insn.
        uint32 fun;
        /// @param stateVersion The state version.
        uint256 stateVersion;
    }

    struct ExecuteMipsInstructionParams {
        /// @param insn The current MIPS instruction at the pc.
        uint32 insn;
        /// @param opcode The opcode value parsed from insn.
        uint32 opcode;
        /// @param fun The function value parsed from insn.
        uint32 fun;
        /// @param rs The source register 1 value.
        uint64 rs;
        /// @param rt The source register 2 value.
        uint64 rt;
        /// @param mem The value fetched from memory for the current instruction.
        uint64 mem;
        /// @param stateVersion The state version.
        uint256 stateVersion;
    }

    /// @param _pc The program counter.
    /// @param _memRoot The current memory root.
    /// @param _insnProofOffset The calldata offset of the memory proof for the current instruction.
    /// @return insn_ The current 32-bit instruction at the pc.
    /// @return opcode_ The opcode value parsed from insn_.
    /// @return fun_ The function value parsed from insn_.
    function getInstructionDetails(
        uint64 _pc,
        bytes32 _memRoot,
        uint256 _insnProofOffset
    )
        internal
        pure
        returns (uint32 insn_, uint32 opcode_, uint32 fun_)
    {
        unchecked {
            if (_pc & 0x3 != 0) {
                revert InvalidPC();
            }
            uint64 word = MIPS64Memory.readMem(_memRoot, _pc & arch.ADDRESS_MASK, _insnProofOffset);
            insn_ = uint32(selectSubWord(_pc, word, 4, false));
            opcode_ = insn_ >> 26; // First 6-bits
            fun_ = insn_ & 0x3f; // Last 6-bits

            return (insn_, opcode_, fun_);
        }
    }

    /// @notice Execute core MIPS step logic.
    /// @return newMemRoot_ The updated merkle root of memory after any modifications, may be unchanged.
    /// @return memUpdated_ True if memory was modified.
    /// @return effMemAddr_ Holds the effective address that was updated if memUpdated_ is true.
    function execMipsCoreStepLogic(CoreStepLogicParams memory _args)
        internal
        pure
        returns (bytes32 newMemRoot_, bool memUpdated_, uint64 effMemAddr_)
    {
        unchecked {
            newMemRoot_ = _args.memRoot;
            memUpdated_ = false;
            effMemAddr_ = 0;

            // j-type j/jal
            if (_args.opcode == 2 || _args.opcode == 3) {
                // Take top 4 bits of the next PC (its 256 MB region), and concatenate with the 26-bit offset
                uint64 target = (_args.cpu.nextPC & signExtend(0xF0000000, 32)) | uint64((_args.insn & 0x03FFFFFF) << 2);
                handleJump(_args, _args.opcode == 2 ? 0 : REG_RA, target);
                return (newMemRoot_, memUpdated_, effMemAddr_);
            }

            // register fetch
            uint64 rs = 0; // source register 1 value
            uint64 rt = 0; // source register 2 / temp value
            uint64 rtReg = uint64((_args.insn >> 16) & 0x1F);

            // R-type or I-type (stores rt)
            rs = _args.registers[(_args.insn >> 21) & 0x1F];
            uint64 rdReg = rtReg;

            // 64-bit opcodes lwu, ldl, ldr
            if (_args.opcode == 0x27 || _args.opcode == 0x1A || _args.opcode == 0x1B) {
                rt = _args.registers[rtReg];
                rdReg = rtReg;
            } else if (_args.opcode == 0 || _args.opcode == 0x1c) {
                // R-type (stores rd)
                rt = _args.registers[rtReg];
                rdReg = uint64((_args.insn >> 11) & 0x1F);
            } else if (_args.opcode < 0x20) {
                // rt is SignExtImm
                // don't sign extend for andi, ori, xori
                if (_args.opcode == 0xC || _args.opcode == 0xD || _args.opcode == 0xe) {
                    // ZeroExtImm
                    rt = uint64(_args.insn & 0xFFFF);
                } else {
                    // SignExtImm
                    rt = signExtendImmediate(_args.insn);
                }
            } else if (_args.opcode >= 0x28 || _args.opcode == 0x22 || _args.opcode == 0x26) {
                // store rt value with store
                rt = _args.registers[rtReg];

                // store actual rt with lwl and lwr
                rdReg = rtReg;
            }

            if ((_args.opcode >= 4 && _args.opcode < 8) || _args.opcode == 1) {
                handleBranch({
                    _cpu: _args.cpu,
                    _registers: _args.registers,
                    _opcode: _args.opcode,
                    _insn: _args.insn,
                    _rtReg: rtReg,
                    _rs: rs
                });
                return (newMemRoot_, memUpdated_, effMemAddr_);
            }

            uint64 storeAddr = U64_MASK;
            // memory fetch (all I-type)
            // we do the load for stores also
            uint64 mem = 0;
            if (_args.opcode >= 0x20 || _args.opcode == OP_LOAD_DOUBLE_LEFT || _args.opcode == OP_LOAD_DOUBLE_RIGHT) {
                // M[R[rs]+SignExtImm]
                rs += signExtendImmediate(_args.insn);
                uint64 addr = rs & arch.ADDRESS_MASK;
                mem = MIPS64Memory.readMem(_args.memRoot, addr, _args.memProofOffset);
                if (_args.opcode >= 0x28) {
                    // store for 32-bit
                    // for 64-bit: ld (0x37) is the only non-store opcode >= 0x28
                    if (_args.opcode != 0x37) {
                        // store
                        storeAddr = addr;
                        // store opcodes don't write back to a register
                        rdReg = 0;
                    }
                }
            }

            // ALU
            // Note: swr outputs more than 8 bytes without the u64_mask
            ExecuteMipsInstructionParams memory params = ExecuteMipsInstructionParams({
                insn: _args.insn,
                opcode: _args.opcode,
                fun: _args.fun,
                rs: rs,
                rt: rt,
                mem: mem,
                stateVersion: _args.stateVersion
            });
            uint64 val = executeMipsInstruction(params) & U64_MASK;

            uint64 funSel = 0x20;
            if (_args.opcode == 0 && _args.fun >= 8 && _args.fun < funSel) {
                if (_args.fun == 8 || _args.fun == 9) {
                    // jr/jalr
                    handleJump(_args, _args.fun == 8 ? 0 : rdReg, rs);
                    return (newMemRoot_, memUpdated_, effMemAddr_);
                }

                if (_args.fun == 0xa) {
                    // movz
                    handleRd(_args.cpu, _args.registers, rdReg, rs, rt == 0);
                    return (newMemRoot_, memUpdated_, effMemAddr_);
                }
                if (_args.fun == 0xb) {
                    // movn
                    handleRd(_args.cpu, _args.registers, rdReg, rs, rt != 0);
                    return (newMemRoot_, memUpdated_, effMemAddr_);
                }

                // lo and hi registers
                // can write back
                if (_args.fun >= 0x10 && _args.fun < funSel) {
                    handleHiLo({
                        _cpu: _args.cpu,
                        _registers: _args.registers,
                        _fun: _args.fun,
                        _rs: rs,
                        _rt: rt,
                        _storeReg: rdReg
                    });
                    return (newMemRoot_, memUpdated_, effMemAddr_);
                }
            }

            // write memory
            if (storeAddr != U64_MASK) {
                newMemRoot_ = MIPS64Memory.writeMem(storeAddr, _args.memProofOffset, val);
                memUpdated_ = true;
                effMemAddr_ = storeAddr;
            }

            // write back the value to destination register
            handleRd(_args.cpu, _args.registers, rdReg, val, true);

            return (newMemRoot_, memUpdated_, effMemAddr_);
        }
    }

    function signExtendImmediate(uint32 _insn) internal pure returns (uint64 offset_) {
        unchecked {
            return signExtend(_insn & 0xFFFF, 16);
        }
    }

    /// @notice Execute an instruction.
    function executeMipsInstruction(ExecuteMipsInstructionParams memory _args) internal pure returns (uint64 out_) {
        uint32 insn = _args.insn;
        uint32 opcode = _args.opcode;
        uint32 fun = _args.fun;
        uint64 rs = _args.rs;
        uint64 rt = _args.rt;
        uint64 mem = _args.mem;
        uint256 stateVersion = _args.stateVersion;
        unchecked {
            if (opcode == 0 || (opcode >= 8 && opcode < 0xF) || opcode == 0x18 || opcode == 0x19) {
                assembly {
                    // transform ArithLogI to SPECIAL
                    switch opcode
                    // addi
                    case 0x8 { fun := 0x20 }
                    // addiu
                    case 0x9 { fun := 0x21 }
                    // stli
                    case 0xA { fun := 0x2A }
                    // sltiu
                    case 0xB { fun := 0x2B }
                    // andi
                    case 0xC { fun := 0x24 }
                    // ori
                    case 0xD { fun := 0x25 }
                    // xori
                    case 0xE { fun := 0x26 }
                    // daddi
                    case 0x18 { fun := 0x2C }
                    // daddiu
                    case 0x19 { fun := 0x2D }
                }

                // sll
                if (fun == 0x00) {
                    uint32 shiftAmt = (insn >> 6) & 0x1F;
                    return signExtend((rt << shiftAmt) & U32_MASK, 32);
                }
                // srl
                else if (fun == 0x02) {
                    return signExtend((rt & U32_MASK) >> ((insn >> 6) & 0x1F), 32);
                }
                // sra
                else if (fun == 0x03) {
                    uint32 shamt = (insn >> 6) & 0x1F;
                    return signExtend((rt & U32_MASK) >> shamt, 32 - shamt);
                }
                // sllv
                else if (fun == 0x04) {
                    uint64 shiftAmt = rs & 0x1F;
                    return signExtend((rt << shiftAmt) & U32_MASK, 32);
                }
                // srlv
                else if (fun == 0x6) {
                    return signExtend((rt & U32_MASK) >> (rs & 0x1F), 32);
                }
                // srav
                else if (fun == 0x07) {
                    // shamt here is different than the typical shamt which comes from the
                    // instruction itself, here it comes from the rs register
                    uint64 shamt = rs & 0x1F;
                    return signExtend((rt & U32_MASK) >> shamt, 32 - shamt);
                }
                // functs in range [0x8, 0x1b] are handled specially by other functions
                // Explicitly enumerate each funct in range to reduce code diff against Go Vm
                // jr
                else if (fun == 0x08) {
                    return rs;
                }
                // jalr
                else if (fun == 0x09) {
                    return rs;
                }
                // movz
                else if (fun == 0x0a) {
                    return rs;
                }
                // movn
                else if (fun == 0x0b) {
                    return rs;
                }
                // syscall
                else if (fun == 0x0c) {
                    return rs;
                }
                // 0x0d - break not supported
                // sync
                else if (fun == 0x0f) {
                    return rs;
                }
                // mfhi
                else if (fun == 0x10) {
                    return rs;
                }
                // mthi
                else if (fun == 0x11) {
                    return rs;
                }
                // mflo
                else if (fun == 0x12) {
                    return rs;
                }
                // mtlo
                else if (fun == 0x13) {
                    return rs;
                }
                // dsllv
                else if (fun == 0x14) {
                    return rt;
                }
                // dsrlv
                else if (fun == 0x16) {
                    return rt;
                }
                // dsrav
                else if (fun == 0x17) {
                    return rt;
                }
                // mult
                else if (fun == 0x18) {
                    return rs;
                }
                // multu
                else if (fun == 0x19) {
                    return rs;
                }
                // div
                else if (fun == 0x1a) {
                    return rs;
                }
                // divu
                else if (fun == 0x1b) {
                    return rs;
                }
                // dmult
                else if (fun == 0x1c) {
                    return rs;
                }
                // dmultu
                else if (fun == 0x1d) {
                    return rs;
                }
                // ddiv
                else if (fun == 0x1e) {
                    return rs;
                }
                // ddivu
                else if (fun == 0x1f) {
                    return rs;
                }
                // The rest includes transformed R-type arith imm instructions
                // add
                else if (fun == 0x20) {
                    return signExtend(uint64(uint32(rs) + uint32(rt)), 32);
                }
                // addu
                else if (fun == 0x21) {
                    return signExtend(uint64(uint32(rs) + uint32(rt)), 32);
                }
                // sub
                else if (fun == 0x22) {
                    return signExtend(uint64(uint32(rs) - uint32(rt)), 32);
                }
                // subu
                else if (fun == 0x23) {
                    return signExtend(uint64(uint32(rs) - uint32(rt)), 32);
                }
                // and
                else if (fun == 0x24) {
                    return (rs & rt);
                }
                // or
                else if (fun == 0x25) {
                    return (rs | rt);
                }
                // xor
                else if (fun == 0x26) {
                    return (rs ^ rt);
                }
                // nor
                else if (fun == 0x27) {
                    return ~(rs | rt);
                }
                // slti
                else if (fun == 0x2a) {
                    return int64(rs) < int64(rt) ? 1 : 0;
                }
                // sltiu
                else if (fun == 0x2b) {
                    return rs < rt ? 1 : 0;
                }
                // dadd
                else if (fun == 0x2c) {
                    return (rs + rt);
                }
                // daddu
                else if (fun == 0x2d) {
                    return (rs + rt);
                }
                // dsub
                else if (fun == 0x2e) {
                    return (rs - rt);
                }
                // dsubu
                else if (fun == 0x2f) {
                    return (rs - rt);
                }
                // dsll
                else if (fun == 0x38) {
                    return rt << ((insn >> 6) & 0x1f);
                }
                // dsrl
                else if (fun == 0x3A) {
                    return rt >> ((insn >> 6) & 0x1f);
                }
                // dsra
                else if (fun == 0x3B) {
                    return uint64(int64(rt) >> ((insn >> 6) & 0x1f));
                }
                // dsll32
                else if (fun == 0x3c) {
                    return rt << (((insn >> 6) & 0x1f) + 32);
                }
                // dsrl32
                else if (fun == 0x3e) {
                    return rt >> (((insn >> 6) & 0x1f) + 32);
                }
                // dsra32
                else if (fun == 0x3f) {
                    return uint64(int64(rt) >> (((insn >> 6) & 0x1f) + 32));
                } else {
                    revert("MIPS64: invalid instruction");
                }
            } else {
                // SPECIAL2
                if (opcode == 0x1C) {
                    // mul
                    if (fun == 0x2) {
                        return signExtend(uint32(int32(uint32(rs)) * int32(uint32(rt))), 32);
                    }
                    // clz, clo
                    else if (fun == 0x20 || fun == 0x21) {
                        if (fun == 0x20) {
                            rs = ~rs;
                        }
                        uint32 i = 0;
                        while (rs & 0x80000000 != 0) {
                            i++;
                            rs <<= 1;
                        }
                        return i;
                    }
                    // dclz, dclo
                    else if (st.featuresForVersion(stateVersion).supportDclzDclo && (fun == 0x24 || fun == 0x25)) {
                        if (fun == 0x24) {
                            rs = ~rs;
                        }
                        uint32 i = 0;
                        while (rs & 0x80000000_00000000 != 0) {
                            i++;
                            rs <<= 1;
                        }
                        return i;
                    }
                }
                // lui
                else if (opcode == 0x0F) {
                    return signExtend(rt << 16, 32);
                }
                // lb
                else if (opcode == 0x20) {
                    return selectSubWord(rs, mem, 1, true);
                }
                // lh
                else if (opcode == 0x21) {
                    return selectSubWord(rs, mem, 2, true);
                }
                // lwl
                else if (opcode == 0x22) {
                    uint32 w = uint32(selectSubWord(rs, mem, 4, false));
                    uint32 val = w << uint32((rs & 3) * 8);
                    uint64 mask = uint64(U32_MASK << uint32((rs & 3) * 8));
                    return signExtend(((rt & ~mask) | uint64(val)) & U32_MASK, 32);
                }
                // lw
                else if (opcode == 0x23) {
                    return selectSubWord(rs, mem, 4, true);
                }
                // lbu
                else if (opcode == 0x24) {
                    return selectSubWord(rs, mem, 1, false);
                }
                //  lhu
                else if (opcode == 0x25) {
                    return selectSubWord(rs, mem, 2, false);
                }
                //  lwr
                else if (opcode == 0x26) {
                    uint32 w = uint32(selectSubWord(rs, mem, 4, false));
                    uint32 val = w >> (24 - (rs & 3) * 8);
                    uint32 mask = U32_MASK >> (24 - (rs & 3) * 8);
                    uint64 lwrResult = (uint32(rt) & ~mask) | val;
                    if (rs & 3 == 3) {
                        // loaded bit 31
                        return signExtend(uint64(lwrResult), 32);
                    } else {
                        // NOTE: cannon64 implementation specific: We leave the upper word untouched
                        uint64 rtMask = 0xFF_FF_FF_FF_00_00_00_00;
                        return ((rt & rtMask) | uint64(lwrResult));
                    }
                }
                //  sb
                else if (opcode == 0x28) {
                    return updateSubWord(rs, mem, 1, rt);
                }
                //  sh
                else if (opcode == 0x29) {
                    return updateSubWord(rs, mem, 2, rt);
                }
                //  swl
                else if (opcode == 0x2a) {
                    uint64 sr = (rs & 3) << 3;
                    uint64 val = ((rt & U32_MASK) >> sr) << (32 - ((rs & 0x4) << 3));
                    uint64 mask = (uint64(U32_MASK) >> sr) << (32 - ((rs & 0x4) << 3));
                    return (mem & ~mask) | val;
                }
                //  sw
                else if (opcode == 0x2b) {
                    return updateSubWord(rs, mem, 4, rt);
                }
                //  swr
                else if (opcode == 0x2e) {
                    uint32 w = uint32(selectSubWord(rs, mem, 4, false));
                    uint64 val = rt << (24 - (rs & 3) * 8);
                    uint64 mask = U32_MASK << uint32(24 - (rs & 3) * 8);
                    uint64 swrResult = (w & ~mask) | uint32(val);
                    return updateSubWord(rs, mem, 4, swrResult);
                }
                // MIPS64
                //  ldl
                else if (opcode == 0x1a) {
                    uint64 sl = (rs & 0x7) << 3;
                    uint64 val = mem << sl;
                    uint64 mask = U64_MASK << sl;
                    return (val | (rt & ~mask));
                }
                //  ldr
                else if (opcode == 0x1b) {
                    uint64 sr = 56 - ((rs & 0x7) << 3);
                    uint64 val = mem >> sr;
                    uint64 mask = U64_MASK << (64 - sr);
                    return (val | (rt & mask));
                }
                //  lwu
                else if (opcode == 0x27) {
                    return ((mem >> (32 - ((rs & 0x4) << 3))) & U32_MASK);
                }
                //  sdl
                else if (opcode == 0x2c) {
                    uint64 sr = (rs & 0x7) << 3;
                    uint64 val = rt >> sr;
                    uint64 mask = U64_MASK >> sr;
                    return (val | (mem & ~mask));
                }
                //  sdr
                else if (opcode == 0x2d) {
                    uint64 sl = 56 - ((rs & 0x7) << 3);
                    uint64 val = rt << sl;
                    uint64 mask = U64_MASK << sl;
                    return (val | (mem & ~mask));
                }
                //  ld
                else if (opcode == 0x37) {
                    return mem;
                }
                //  sd
                else if (opcode == 0x3F) {
                    return rt;
                } else {
                    revert("MIPS64: invalid instruction");
                }
            }
            revert("MIPS64: invalid instruction");
        }
    }

    /// @notice Extends the value leftwards with its most significant bit (sign extension).
    function signExtend(uint64 _dat, uint64 _idx) internal pure returns (uint64 out_) {
        unchecked {
            bool isSigned = (_dat >> (_idx - 1)) & 1 != 0;
            uint256 signed = ((1 << (arch.WORD_SIZE - _idx)) - 1) << _idx;
            uint256 mask = (1 << _idx) - 1;
            return uint64(_dat & mask | (isSigned ? signed : 0));
        }
    }

    /// @notice Handles a branch instruction, updating the MIPS state PC where needed.
    /// @param _cpu Holds the state of cpu scalars pc, nextPC, hi, lo.
    /// @param _registers Holds the current state of the cpu registers.
    /// @param _opcode The opcode of the branch instruction.
    /// @param _insn The instruction to be executed.
    /// @param _rtReg The register to be used for the branch.
    /// @param _rs The register to be compared with the branch register.
    function handleBranch(
        st.CpuScalars memory _cpu,
        uint64[32] memory _registers,
        uint32 _opcode,
        uint32 _insn,
        uint64 _rtReg,
        uint64 _rs
    )
        internal
        pure
    {
        unchecked {
            bool shouldBranch = false;

            if (_cpu.nextPC != _cpu.pc + 4) {
                revert("MIPS64: branch in delay slot");
            }

            // beq/bne: Branch on equal / not equal
            if (_opcode == 4 || _opcode == 5) {
                uint64 rt = _registers[_rtReg];
                shouldBranch = (_rs == rt && _opcode == 4) || (_rs != rt && _opcode == 5);
            }
            // blez: Branches if instruction is less than or equal to zero
            else if (_opcode == 6) {
                shouldBranch = int64(_rs) <= 0;
            }
            // bgtz: Branches if instruction is greater than zero
            else if (_opcode == 7) {
                shouldBranch = int64(_rs) > 0;
            }
            // bltz/bgez: Branch on less than zero / greater than or equal to zero
            else if (_opcode == 1) {
                // regimm
                uint32 rtv = ((_insn >> 16) & 0x1F);
                if (rtv == 0) {
                    shouldBranch = int64(_rs) < 0;
                }
                // bltzal
                if (rtv == 0x10) {
                    shouldBranch = int64(_rs) < 0;
                    _registers[REG_RA] = _cpu.pc + 8; // always set regardless of branch taken
                }
                if (rtv == 1) {
                    shouldBranch = int64(_rs) >= 0;
                }
                // bgezal (i.e. bal mnemonic)
                if (rtv == 0x11) {
                    shouldBranch = int64(_rs) >= 0;
                    _registers[REG_RA] = _cpu.pc + 8; // always set regardless of branch taken
                }
            }

            // Update the state's previous PC
            uint64 prevPC = _cpu.pc;

            // Execute the delay slot first
            _cpu.pc = _cpu.nextPC;

            // If we should branch, update the PC to the branch target
            // Otherwise, proceed to the next instruction
            if (shouldBranch) {
                _cpu.nextPC = prevPC + 4 + (signExtend(_insn & 0xFFFF, 16) << 2);
            } else {
                _cpu.nextPC = _cpu.nextPC + 4;
            }
        }
    }

    /// @notice Handles HI and LO register instructions. It also additionally handles doubleword variable shift
    /// operations
    /// @param _cpu Holds the state of cpu scalars pc, nextPC, hi, lo.
    /// @param _registers Holds the current state of the cpu registers.
    /// @param _fun The function code of the instruction.
    /// @param _rs The value of the RS register.
    /// @param _rt The value of the RT register.
    /// @param _storeReg The register to store the result in.
    function handleHiLo(
        st.CpuScalars memory _cpu,
        uint64[32] memory _registers,
        uint32 _fun,
        uint64 _rs,
        uint64 _rt,
        uint64 _storeReg
    )
        internal
        pure
    {
        unchecked {
            uint64 val = 0;

            // mfhi: Move the contents of the HI register into the destination
            if (_fun == 0x10) {
                val = _cpu.hi;
            }
            // mthi: Move the contents of the source into the HI register
            else if (_fun == 0x11) {
                _cpu.hi = _rs;
            }
            // mflo: Move the contents of the LO register into the destination
            else if (_fun == 0x12) {
                val = _cpu.lo;
            }
            // mtlo: Move the contents of the source into the LO register
            else if (_fun == 0x13) {
                _cpu.lo = _rs;
            }
            // mult: Multiplies `rs` by `rt` and stores the result in HI and LO registers
            else if (_fun == 0x18) {
                uint64 acc = uint64(int64(int32(uint32(_rs))) * int64(int32(uint32(_rt))));
                _cpu.hi = signExtend(uint64(acc >> 32), 32);
                _cpu.lo = signExtend(uint64(uint32(acc)), 32);
            }
            // multu: Unsigned multiplies `rs` by `rt` and stores the result in HI and LO registers
            else if (_fun == 0x19) {
                uint64 acc = uint64(uint32(_rs)) * uint64(uint32(_rt));
                _cpu.hi = signExtend(uint64(acc >> 32), 32);
                _cpu.lo = signExtend(uint64(uint32(acc)), 32);
            }
            // div: Divides `rs` by `rt`.
            // Stores the quotient in LO
            // And the remainder in HI
            else if (_fun == 0x1a) {
                if (uint32(_rt) == 0) {
                    revert("MIPS64: division by zero");
                }
                _cpu.hi = signExtend(uint32(int32(uint32(_rs)) % int32(uint32(_rt))), 32);
                _cpu.lo = signExtend(uint32(int32(uint32(_rs)) / int32(uint32(_rt))), 32);
            }
            // divu: Unsigned divides `rs` by `rt`.
            // Stores the quotient in LO
            // And the remainder in HI
            else if (_fun == 0x1b) {
                if (uint32(_rt) == 0) {
                    revert("MIPS64: division by zero");
                }
                _cpu.hi = signExtend(uint64(uint32(_rs) % uint32(_rt)), 32);
                _cpu.lo = signExtend(uint64(uint32(_rs) / uint32(_rt)), 32);
            }
            // dsllv
            else if (_fun == 0x14) {
                val = _rt << (_rs & 0x3F);
            }
            // dsrlv
            else if (_fun == 0x16) {
                val = _rt >> (_rs & 0x3F);
            }
            // dsrav
            else if (_fun == 0x17) {
                val = uint64(int64(_rt) >> (_rs & 0x3F));
            }
            // dmult
            else if (_fun == 0x1c) {
                int128 res = int128(int64(_rs)) * int128(int64(_rt));
                _cpu.hi = uint64(int64(res >> 64));
                _cpu.lo = uint64(uint128(res) & U64_MASK);
            }
            // dmultu
            else if (_fun == 0x1d) {
                uint128 res = uint128(_rs) * uint128(_rt);
                _cpu.hi = uint64(res >> 64);
                _cpu.lo = uint64(res);
            }
            // ddiv
            else if (_fun == 0x1e) {
                if (_rt == 0) {
                    revert("MIPS64: division by zero");
                }
                _cpu.hi = uint64(int64(_rs) % int64(_rt));
                _cpu.lo = uint64(int64(_rs) / int64(_rt));
            }
            // ddivu
            else if (_fun == 0x1f) {
                if (_rt == 0) {
                    revert("MIPS64: division by zero");
                }
                _cpu.hi = _rs % _rt;
                _cpu.lo = _rs / _rt;
            }

            // Store the result in the destination register, if applicable
            if (_storeReg != 0) {
                _registers[_storeReg] = val;
            }

            // Update the PC
            _cpu.pc = _cpu.nextPC;
            _cpu.nextPC = _cpu.nextPC + 4;
        }
    }

    /// @notice Handles a jump instruction, updating the MIPS state PC where needed.
    /// @dev The _cpuAndRegisters is stored in memory to avoid stack limit issues.
    /// @param _cpuAndRegisters Holds the state of cpu scalars (pc, nextPC, hi, lo) and the current state of the cpu
    /// registers.
    /// @param _linkReg The register to store the link to the instruction after the delay slot instruction.
    /// @param _dest The destination to jump to.
    function handleJump(CoreStepLogicParams memory _cpuAndRegisters, uint64 _linkReg, uint64 _dest) internal pure {
        unchecked {
            if (_cpuAndRegisters.cpu.nextPC != _cpuAndRegisters.cpu.pc + 4) {
                revert("MIPS64: jump in delay slot");
            }

            // Update the next PC to the jump destination.
            uint64 prevPC = _cpuAndRegisters.cpu.pc;
            _cpuAndRegisters.cpu.pc = _cpuAndRegisters.cpu.nextPC;
            _cpuAndRegisters.cpu.nextPC = _dest;

            // Update the link-register to the instruction after the delay slot instruction.
            if (_linkReg != 0) {
                _cpuAndRegisters.registers[_linkReg] = prevPC + 8;
            }
        }
    }

    /// @notice Handles a storing a value into a register.
    /// @param _cpu Holds the state of cpu scalars pc, nextPC, hi, lo.
    /// @param _registers Holds the current state of the cpu registers.
    /// @param _storeReg The register to store the value into.
    /// @param _val The value to store.
    /// @param _conditional Whether or not the store is conditional.
    function handleRd(
        st.CpuScalars memory _cpu,
        uint64[32] memory _registers,
        uint64 _storeReg,
        uint64 _val,
        bool _conditional
    )
        internal
        pure
    {
        unchecked {
            // The destination register must be valid.
            require(_storeReg < 32, "MIPS64: valid register");

            // Never write to reg 0, and it can be conditional (movz, movn).
            if (_storeReg != 0 && _conditional) {
                _registers[_storeReg] = _val;
            }

            // Update the PC.
            _cpu.pc = _cpu.nextPC;
            _cpu.nextPC = _cpu.nextPC + 4;
        }
    }

    /// @notice Selects a subword of byteLength size contained in memWord based on the low-order bits of vaddr
    /// @param _vaddr The virtual address of the the subword.
    /// @param _memWord The full word to select a subword from.
    /// @param _byteLength The size of the subword.
    /// @param _signExtend Whether to sign extend the selected subwrod.
    function selectSubWord(
        uint64 _vaddr,
        uint64 _memWord,
        uint64 _byteLength,
        bool _signExtend
    )
        internal
        pure
        returns (uint64 retval_)
    {
        (uint64 dataMask, uint64 bitOffset, uint64 bitLength) = calculateSubWordMaskAndOffset(_vaddr, _byteLength);
        retval_ = (_memWord >> bitOffset) & dataMask;
        if (_signExtend) {
            retval_ = signExtend(retval_, bitLength);
        }
        return retval_;
    }

    /// @notice Returns a word that has been updated by the specified subword at bit positions determined by the virtual
    /// address
    /// @param _vaddr The virtual address of the subword.
    /// @param _memWord The full word to update.
    /// @param _byteLength The size of the subword.
    /// @param _value The subword that updates _memWord.
    function updateSubWord(
        uint64 _vaddr,
        uint64 _memWord,
        uint64 _byteLength,
        uint64 _value
    )
        internal
        pure
        returns (uint64 word_)
    {
        (uint64 dataMask, uint64 bitOffset,) = calculateSubWordMaskAndOffset(_vaddr, _byteLength);
        uint64 subWordValue = dataMask & _value;
        uint64 memUpdateMask = dataMask << bitOffset;
        return subWordValue << bitOffset | (~memUpdateMask) & _memWord;
    }

    function calculateSubWordMaskAndOffset(
        uint64 _vaddr,
        uint64 _byteLength
    )
        internal
        pure
        returns (uint64 dataMask_, uint64 bitOffset_, uint64 bitLength_)
    {
        uint64 bitLength = _byteLength << 3;
        uint64 dataMask = ~uint64(0) >> (arch.WORD_SIZE - bitLength);

        // Figure out sub-word index based on the low-order bits in vaddr
        uint64 byteIndexMask = _vaddr & arch.EXT_MASK & ~(_byteLength - 1);
        uint64 maxByteShift = arch.WORD_SIZE_BYTES - _byteLength;
        uint64 byteIndex = _vaddr & byteIndexMask;
        uint64 bitOffset = (maxByteShift - byteIndex) << 3;

        return (dataMask, bitOffset, bitLength);
    }
}
