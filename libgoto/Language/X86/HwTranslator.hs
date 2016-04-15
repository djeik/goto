{-|
Module      : Language.X86.HwTranslator
Description : Virtual Asm to Hardware Asm translator
Copyright   : (c) Jacob Errington and Frederic Lafrance, 2016
License     : MIT
Maintainer  : goto@mail.jerrington.me
Stability   : experimental

This module is reponsible for the translation between virtual and hardware
assembly. The main steps of this translation are:

    * Compute lifetimes for every virtual register in the program (see
      "Language.X86.Lifetime")
    * Allocate hardware locations for every virtual register (see
      "Language.X86.HwAllocator")
-}

{-# LANGUAGE ScopedTypeVariables #-}

module Language.X86.HwTranslator where

import Language.Common.Storage
import Language.X86.Core
import Language.X86.Hardware
import Language.X86.Hardware.Registers
import Language.X86.Lifetime
import Language.X86.Virtual

import Control.Monad.Free
import Control.Monad.Except
import Control.Monad.State

import qualified Data.Map.Strict as M

asm :: Monad m => m a -> HardwareTranslationT m a
asm = HardwareTranslationT . lift . lift

translate
    :: forall addr label
    . M.Map SizedVirtualRegister HardwareLocation
    -> [(SizedHardwareRegister, LifetimeSpan)]
    -> Int
    -> VirtualAsm addr label ()
    -> HardwareTranslation addr label ()
translate vToH live stkSz = iterM phi where
    phi :: AsmF addr label (Operand SizedVirtualRegister addr label) (HardwareTranslation addr label ())
        -> HardwareTranslation addr label ()
    phi a = case a of

        -- Pass through here
        Here f -> do
            h <- asm here
            f h

        -- Pass through newLabel
        NewLabel f -> do
            l <- asm newLabel
            f l

        -- Pass through setLabel
        SetLabel l ad n -> do
            asm $ setLabel l ad
            n

        Prologue di n -> case di of

            -- Function prologue: make space on the stack for spills, push
            -- safe registers that are in use throughout this function.
            Save -> do
                off <- gets _currentSpillOffset
                pregs <- gets _safeRegistersUsed
                asm $ sub rsp (Immediate $ ImmI $ fromIntegral $ -(off - stkSz))
                void $ forM pregs (\(SizedRegister _ reg) -> case reg of
                        FloatingHwRegister _ -> throwError $ InvariantViolation
                            "No floating register is safe"
                        IntegerHwRegister r -> asm $ push $ fixedIntReg64 r
                    )
                n

            -- Mirror image of Prologue Save (pop safe registers, clear the
            -- space on the stack.
            Load -> do
                off <- gets _currentSpillOffset
                pregs <- gets _safeRegistersUsed

                -- Obviously, this popping needs to be done in reverse.
                void $ forM (reverse pregs) (\(SizedRegister _ reg) -> case reg of
                        FloatingHwRegister _ -> throwError $ InvariantViolation
                            "No floating register is safe"
                        IntegerHwRegister r -> asm $ pop $ fixedIntReg64 r
                    )

                asm $ add rsp (Immediate $ ImmI $ fromIntegral $ -(off - stkSz))
                n

        Scratch di n ->
            case di of
                -- On a scratch save, push all the scratch registers that are
                -- currently live.
                Save -> do
                    i <- gets _ip
                    let sr = getLiveScratch i live
                    modify $ \s -> s { _latestSavedRegisters = sr }
                    void $ forM sr (\r -> asm $ push $ DirectRegister r)
                    n

                -- Mirror: pop in reverse the registers we had saved before.
                Load -> do
                    sr <- gets _latestSavedRegisters
                    void $ forM (reverse sr) (\r -> asm $ pop $ DirectRegister r)
                    n

        Emit i n -> do
            translateInst i
            modify $ \s -> s {_ip = _ip s + 1}
            n

    translateInst i = case i of
        Ret -> asm ret
        Mov v1 v2 -> (v1, v2) ?~> mov
        Call v -> v !~> call
        Add v1 v2 -> (v1, v2) ?~> add
        Sub v1 v2 -> (v1, v2) ?~> sub
        Mul s v1 v2 mv3 -> undefined
        Xor v1 v2 -> (v1, v2) ?~> xor  -- Definition of Mul will change
        Inc v -> v !~> inc
        Dec v -> v !~> dec
        Push v -> v !~> push
        Pop v -> v !~> pop
        Nop -> asm nop
        Syscall -> asm syscall
        Int v -> v !~> int
        Cmp v1 v2 -> (v1, v2) ?~> cmp
        Test v1 v2 -> (v1, v2) ?~> test
        Sal v1 v2 -> (v1, v2) ?~> sal
        Sar v1 v2 -> (v1, v2) ?~> sar
        Jump cond v -> v !~> (jump cond)
        Setc cond v -> v !~> (setc cond)
        Neg1 v -> v !~> neg1
        Neg2 v -> v !~> neg2

    -- Translates an operand from virtual to hardware, and synthesizes the
    -- given instruction that uses the hardware operand.
    --
    -- This operator is pronounced "translate".
    v !~> fInst = do
        v' <- translateOp v
        asm $ fInst v'

    {- A two-operand version of (!~>). A check is made to ensure that the
    operands are not both indirects. If they are, then we go from this:
        inst [dst] [src]
    to:
        mov rax, [src]
        inst [dst] rax
    This is okay because rax is never allocated, specifically for this purpose.
    -}
    (v1, v2) ?~> fInst = do
        v1' <- translateOp v1
        v2' <- translateOp v2
        case (v1, v2) of
            (IndirectRegister _, IndirectRegister _) -> do
                asm $ mov rax v2'
                asm $ fInst v1' rax
            _ -> asm $ fInst v1' v2'

    translateOp
        :: VirtualOperand addr label
        -> HardwareTranslation addr label (HardwareOperand addr label)
    translateOp o = case o of
        -- Any non-reg operand is just passed as-is. We have to do this boilerplate
        -- for typechecking reasons.
        Address a -> pure $ Address a
        Label l -> pure $ Label l
        Internal s -> pure $ Internal s
        External s -> pure $ External s
        Immediate i -> pure $ Immediate i

        {- Direct registers: check the translation table. If it got an actual
            hardware register, use it. If it got spilled, generate an offset
            from rbp. -}
        (DirectRegister r) -> case M.lookup r vToH of
            Just loc -> case loc of
                Reg r' _ -> pure $ DirectRegister r'
                Mem i -> pure $ IndirectRegister $ Offset (fromIntegral i) $
                        SizedRegister Extended64 $ IntegerHwRegister Rbp
                Unassigned -> throwError $ InvariantViolation
                    "Register has not been assigned"
            Nothing -> throwError $ InvariantViolation
                "Virtual register with no corresponding hardware location"

        {- Indirect registers: normally these should only be generated with
        fixed hardware registers. If we end up with an indirect virtual, then
        we're in a problematic situation, because that virtual could have been
        spilled, which creates a second layer of indirection. There's ways of
        dealing with that in instructions with one operand, but when you move up
        to two operands, you might end up in a situation where you need to push
        another register to make enough room for those operands.

        Bottom line: an error is thrown if the register was spilled.
        -}
        (IndirectRegister off) -> case off of
            Offset d r -> case M.lookup r vToH of
                Just loc -> case loc of
                    Reg r' _ -> pure $ IndirectRegister $ Offset d r'
                    Mem _ -> throwError $ InvariantViolation
                        "Spilled virtual indirect register"
                    Unassigned -> throwError $ InvariantViolation
                        "Register has not been assigned."
                Nothing -> throwError $ InvariantViolation
                    "Register has no corresponding hardware location"

-- | Given an offset, constructs the operand to access the spill location
-- associated with it.
spillOperand :: Int -> HardwareOperand addr label
spillOperand i = IndirectRegister $ Offset (fromIntegral i) $
                SizedRegister Extended64 $ IntegerHwRegister Rbp

-- | Obtains all the unsafe registers that are live at the given program point.
getLiveScratch
    :: Int
    -> [(SizedHardwareRegister, LifetimeSpan)]
    -> [SizedHardwareRegister]
getLiveScratch i = map fst . filter (\(h, l) ->
    h `elem` scratchRegisters -- The register must be scratch.
    && i >= _start l && i <= _end l) -- Its lifetime must encompass the ip.


-- | Calculates the total offset required for spills, and verifies which safe
-- registers are used throughout the function.
--
-- Returns a new version of the register pairings in which all spills have their
-- proper offset computed.
computeAllocState :: [RegisterPairing] -> HardwareTranslation addr label [RegisterPairing]
computeAllocState = foldl (\acc (v, h) -> do
    acc' <- acc
    case h of
        Unassigned -> throwError $ InvariantViolation "A hardware location should\
                                                        \ have been assigned"
        Mem _ -> do
            let space = storageSize $ getVRegSize v
            off <- gets _currentSpillOffset
            modify $ \s -> s { _currentSpillOffset = off - space}
            pure $ (v, Mem space):acc'

        Reg r _ -> do
            when (r `elem` safeRegisters)
                $ modify $ \s -> s { _safeRegistersUsed = r:(_safeRegistersUsed s) }
            pure $ (v, h):acc'
    ) (pure [])

getVRegSize :: SizedVirtualRegister -> RegisterSize
getVRegSize (SizedRegister sz _) = sz

