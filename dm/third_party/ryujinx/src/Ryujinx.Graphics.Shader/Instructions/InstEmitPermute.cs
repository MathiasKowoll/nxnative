using System;
using Ryujinx.Graphics.Shader.Decoders;
using Ryujinx.Graphics.Shader.IntermediateRepresentation;
using Ryujinx.Graphics.Shader.Translation;

using static Ryujinx.Graphics.Shader.Instructions.InstEmitHelper;
using static Ryujinx.Graphics.Shader.IntermediateRepresentation.OperandHelper;

namespace Ryujinx.Graphics.Shader.Instructions
{
    static partial class InstEmit
    {
        public static void PrmtR(EmitterContext context)
        {
            InstPrmtR op = context.GetOp<InstPrmtR>();
            EmitPrmt(context, GetSrcReg(context, op.SrcA), GetSrcReg(context, op.SrcB),
                GetSrcReg(context, op.SrcC), op.Dest, op.PMode);
        }

        public static void PrmtI(EmitterContext context)
        {
            InstPrmtI op = context.GetOp<InstPrmtI>();
            EmitPrmt(context, GetSrcReg(context, op.SrcA), GetSrcImm(context, Imm20ToSInt(op.Imm20)),
                GetSrcReg(context, op.SrcC), op.Dest, op.PMode);
        }

        public static void PrmtC(EmitterContext context)
        {
            InstPrmtC op = context.GetOp<InstPrmtC>();
            EmitPrmt(context, GetSrcReg(context, op.SrcA), GetSrcCbuf(context, op.CbufSlot, op.CbufOffset),
                GetSrcReg(context, op.SrcC), op.Dest, op.PMode);
        }

        public static void PrmtRc(EmitterContext context)
        {
            InstPrmtRc op = context.GetOp<InstPrmtRc>();
            EmitPrmt(context, GetSrcReg(context, op.SrcA), GetSrcReg(context, op.SrcC),
                GetSrcCbuf(context, op.CbufSlot, op.CbufOffset), op.Dest, op.PMode);
        }

        private static void EmitPrmt(EmitterContext context, Operand srcA, Operand control, Operand srcC, int rd, PMode mode)
        {
            // Maxwell operand B is the selector; PTX lists it after both data operands.
            // Bytes 0..3 come from A, 4..7 from C. Generic selectors also replicate
            // a source byte's sign bit when bit 3 is set. Specialized modes never do.
            Operand result = Const(0);
            Operand start = context.BitwiseAnd(control, Const(3));
            for (int i = 0; i < 4; i++)
            {
                Operand selector = mode switch
                {
                    0 => context.BitfieldExtractU32(control, Const(i * 4), Const(4)),
                    PMode.F4e => context.IAdd(start, Const(i)),
                    PMode.B4e => context.BitwiseAnd(context.IAdd(start, Const(8 - i)), Const(7)),
                    PMode.Rc8 => start,
                    PMode.Ecl => context.IMaximumU32(start, Const(i)),
                    PMode.Ecr => context.IMinimumU32(start, Const(i)),
                    PMode.Rc16 => context.IAdd(context.ShiftLeft(context.BitwiseAnd(start, Const(1)), Const(1)), Const(i & 1)),
                    _ => throw new InvalidOperationException($"Invalid PRMT mode {(int)mode}.")
                };
                Operand data = context.ConditionalSelect(
                    context.ICompareEqual(context.BitwiseAnd(selector, Const(4)), Const(0)), srcA, srcC);
                Operand shift = context.ShiftLeft(context.BitwiseAnd(selector, Const(3)), Const(3));
                Operand value = context.BitfieldExtractU32(data, shift, Const(8));
                if (mode == 0)
                {
                    Operand sign = context.INegate(context.ShiftRightU32(value, Const(7)));
                    value = context.ConditionalSelect(
                        context.ICompareEqual(context.BitwiseAnd(selector, Const(8)), Const(0)), value, sign);
                }
                result = context.BitwiseOr(result, context.ShiftLeft(context.BitwiseAnd(value, Const(255)), Const(i * 8)));
            }
            context.Copy(GetDest(rd), result);
        }
    }
}
