#include "llvm_ir.h"
#include "debug.h"
#include <llvm/IR/Verifier.h>
#include <llvm/Support/raw_ostream.h>
#include <llvm/IR/Constants.h>
#include <iostream>

llvm::LLVMContext context;
llvm::Module* module = nullptr;
llvm::IRBuilder<> builder(context);

// Where "break" and "continue" jump to. Every loop pushes its targets when
// its body starts and pops them at the end; a switch pushes a break target.
// The innermost loop/switch is always at the back of the vector.
std::vector<llvm::BasicBlock*> breakTargets;
std::vector<llvm::BasicBlock*> continueTargets;

// After return, break or continue, the current block is finished. If more
// statements follow (dead code, e.g. "return 1; x = 2;"), they still need a
// block to go into, so start a new one. Nothing jumps to it, which is fine.
static void startBlockAfterJump() {
    llvm::Function* func = builder.GetInsertBlock()->getParent();
    llvm::BasicBlock* afterJump = llvm::BasicBlock::Create(context, "after.jump", func);
    builder.SetInsertPoint(afterJump);
}

void initLLVM(const std::string& moduleName) {
    if (module) {
        if (verbose) std::cout << "DEBUG: Module already initialized, skipping\n";
        return;
    }
    module = new llvm::Module(moduleName, context);
    if (verbose) std::cout << "Initialized LLVM module: " << moduleName << std::endl;
}

llvm::Type* getLLVMType(SymbolType type) {
    if (verbose) std::cout << "DEBUG: Getting LLVM type for SymbolType " << type << std::endl;
    switch (type) {
        case TYPE_INT: return llvm::Type::getInt32Ty(context);
        case TYPE_FLOAT: return llvm::Type::getFloatTy(context);
        case TYPE_BOOL: return llvm::Type::getInt1Ty(context);
        case TYPE_VOID: return llvm::Type::getVoidTy(context);
        default:
            std::cerr << "ERROR: Unknown SymbolType " << type << std::endl;
            return nullptr;
    }
}

// printf and scanf are declared once per module and reused by every call.
// Declaring them again would make LLVM rename the copy to printf.1, which
// doesn't exist in the C library, so the program would fail to link.
llvm::Function* getPrintfFunction() {
    if (llvm::Function* existing = module->getFunction("printf")) {
        return existing;
    }
    llvm::FunctionType* printfType = llvm::FunctionType::get(
        llvm::Type::getInt32Ty(context),
        {llvm::Type::getInt8PtrTy(context)},
        true
    );
    return llvm::Function::Create(
        printfType,
        llvm::Function::ExternalLinkage,
        "printf",
        module
    );
}

llvm::Function* getScanfFunction() {
    if (llvm::Function* existing = module->getFunction("scanf")) {
        return existing;
    }
    llvm::FunctionType* scanfType = llvm::FunctionType::get(
        llvm::Type::getInt32Ty(context),
        {llvm::Type::getInt8PtrTy(context)},
        true
    );
    return llvm::Function::Create(
        scanfType,
        llvm::Function::ExternalLinkage,
        "scanf",
        module
    );
}

llvm::Function* generateFunctionIR(const std::string& name, SymbolType returnType, Param* params, bool isDefined) {
    if (verbose) std::cout << "DEBUG: generateFunctionIR for " << name << ", isDefined=" << isDefined << std::endl;
    if (!module) {
        std::cerr << "ERROR: Module is null in generateFunctionIR\n";
        return nullptr;
    }
    std::vector<llvm::Type*> paramTypes;
    Param* current = params;
    while (current) {
        if (current->name) {
            if (verbose) std::cout << "DEBUG: Parameter " << current->name << ", type=" << current->type << std::endl;
        } else {
            if (verbose) std::cout << "DEBUG: Parameter (no name), type=" << current->type << std::endl;
        }
        llvm::Type* paramType = getLLVMType(current->type);
        if (!paramType) {
            std::cerr << "ERROR: Invalid parameter type for " << (current->name ? current->name : "unnamed") << std::endl;
            return nullptr;
        }
        paramTypes.push_back(paramType);
        current = current->next;
    }

    llvm::FunctionType* funcType = llvm::FunctionType::get(
        getLLVMType(returnType),
        paramTypes,
        false
    );
    if (!funcType) {
        std::cerr << "ERROR: Failed to create function type\n";
        return nullptr;
    }

    // A prototype like "int f();" may already have created this function.
    // Reuse it so calls made before the definition point at the same @f.
    // (Creating it again would make LLVM rename the new one to @f.1.)
    llvm::Function* function = module->getFunction(name);
    if (function) {
        if (!function->empty()) {
            std::cerr << "ERROR: Function " << name << " already has a body\n";
            return nullptr;
        }
        // The prototype and this declaration must agree on return and parameter types
        if (function->getFunctionType() != funcType) {
            std::cerr << "ERROR: Conflicting types for function " << name << std::endl;
            return nullptr;
        }
        if (verbose) std::cout << "DEBUG: Reusing earlier declaration of " << name << std::endl;
    } else {
        function = llvm::Function::Create(
            funcType,
            llvm::Function::ExternalLinkage,
            name,
            module
        );
        if (verbose) std::cout << "DEBUG: Created function " << name << std::endl;
    }

    if (!isDefined) {
        if (verbose) std::cout << "DEBUG: Returning function declaration\n";
        return function; // Declaration only
    }

    llvm::BasicBlock* entry = llvm::BasicBlock::Create(context, "entry", function);
    if (verbose) std::cout << "DEBUG: Created entry block for " << name << std::endl;
    builder.SetInsertPoint(entry);

    // Allocate and store parameters
    current = params;
    auto argIt = function->arg_begin();
    while (current && argIt != function->arg_end()) {
        if (!current->name) {
            std::cerr << "ERROR: Null parameter name in function " << name << std::endl;
            return nullptr;
        }
        argIt->setName(current->name);
        llvm::AllocaInst* alloca = builder.CreateAlloca(getLLVMType(current->type), nullptr, current->name);
        builder.CreateStore(&*argIt, alloca);
        current->value = alloca;
        if (verbose) std::cout << "Stored parameter " << current->name << " in function " << name << std::endl;
        current = current->next;
        ++argIt;
    }
    if (current || argIt != function->arg_end()) {
        std::cerr << "ERROR: Mismatch in parameter count for " << name << std::endl;
        function->eraseFromParent();
        return nullptr;
    }

    if (verbose) std::cout << "DEBUG: Function " << name << " generated successfully\n";
    return function;
}

// A local variable's stack memory (alloca) is always created at the start of
// the function's entry block, not where the declaration appears. An alloca
// inside a loop body would grab NEW stack memory on every iteration, and a
// long loop would run out of stack. The value is still stored where the
// declaration appears, so the variable behaves exactly the same.
static llvm::AllocaInst* createEntryBlockAlloca(llvm::Type* type, const std::string& name) {
    llvm::Function* func = builder.GetInsertBlock()->getParent();
    llvm::BasicBlock& entry = func->getEntryBlock();
    llvm::IRBuilder<> entryBuilder(&entry, entry.begin());
    return entryBuilder.CreateAlloca(type, nullptr, name);
}

llvm::Value* generateVariableDeclIR(const std::string& name, SymbolType type, int scope) {
    if (verbose) std::cout << "DEBUG: Generating variable decl for " << name << ", scope=" << scope << std::endl;
    llvm::Type* llvmType = getLLVMType(type);
    if (!llvmType) {
        std::cerr << "ERROR: Invalid type for variable " << name << std::endl;
        return nullptr;
    }
    // Scope 0 = outside every function. A global is not stack memory, so it
    // can't be an alloca; it lives in the module itself and starts at zero.
    if (scope == 0) {
        return new llvm::GlobalVariable(*module, llvmType, false,
                                        llvm::GlobalValue::InternalLinkage,
                                        llvm::Constant::getNullValue(llvmType), name);
    }
    return createEntryBlockAlloca(llvmType, name);
}

// Globals are initialized before the program runs, so their initial value
// must be a constant known at compile time (e.g. 5 or 2 + 3, which IRBuilder
// folds into a single constant). Returns false if it isn't.
bool setGlobalInitializerIR(llvm::Value* global, llvm::Value* value) {
    if (!global || !value || !llvm::isa<llvm::Constant>(value)) {
        return false;
    }
    // At scope 0, generateVariableDeclIR always creates a GlobalVariable
    llvm::GlobalVariable* gv = (llvm::GlobalVariable*)global;
    llvm::Constant* init = (llvm::Constant*)value;
    if (init->getType() != gv->getValueType()) {
        return false;
    }
    gv->setInitializer(init);
    return true;
}

// The builder only has an insert block while we are inside a function body
bool insideFunction() {
    return builder.GetInsertBlock() != nullptr;
}

llvm::Value* generateArrayDeclIR(const std::string& name, SymbolType type, int size, int scope) {
    if (verbose) std::cout << "DEBUG: Generating array decl for " << name << ", size=" << size << ", scope=" << scope << std::endl;
    llvm::Type* elementType = getLLVMType(type);
    if (!elementType) {
        std::cerr << "ERROR: Invalid type for array " << name << std::endl;
        return nullptr;
    }
    llvm::ArrayType* arrayType = llvm::ArrayType::get(elementType, size);
    if (scope == 0) {
        // Global array, zero-initialized like a global variable
        return new llvm::GlobalVariable(*module, arrayType, false,
                                        llvm::GlobalValue::InternalLinkage,
                                        llvm::Constant::getNullValue(arrayType), name);
    }
    return createEntryBlockAlloca(arrayType, name);
}

// Address of arr[index]. The array's element type and size come from the
// symbol table. GEP ("get element pointer") takes two indices here: the
// first (0) steps through the pointer to the array itself, the second
// picks the element inside it. GEP only computes the address; it doesn't
// read or write memory.
llvm::Value* getArrayElementPtrIR(llvm::Value* array, SymbolType elemType, int size, llvm::Value* index) {
    if (verbose) std::cout << "DEBUG: Generating array element address\n";
    if (!array || !index) {
        return nullptr;
    }
    llvm::Type* arrayType = llvm::ArrayType::get(getLLVMType(elemType), size);
    llvm::Value* zero = llvm::ConstantInt::get(context, llvm::APInt(32, 0));
    return builder.CreateInBoundsGEP(arrayType, array, {zero, index}, "elemptr");
}

llvm::Value* generateArrayLoadIR(llvm::Value* array, SymbolType elemType, int size, llvm::Value* index) {
    llvm::Value* ptr = getArrayElementPtrIR(array, elemType, size, index);
    if (!ptr) {
        return nullptr;
    }
    return builder.CreateLoad(getLLVMType(elemType), ptr, "elem");
}

void generateArrayStoreIR(llvm::Value* array, SymbolType elemType, int size, llvm::Value* index, llvm::Value* value) {
    llvm::Value* ptr = getArrayElementPtrIR(array, elemType, size, index);
    if (ptr && value) {
        builder.CreateStore(value, ptr);
    }
}

llvm::Value* generateExprIR(SymbolType exprType, const std::string& op, llvm::Value* lhs, llvm::Value* rhs, const std::string& ident, int number, float floatNum, bool boolVal) {
    if (verbose) std::cout << "DEBUG: Generating expr, op=" << op << ", ident=" << ident << ", number=" << number << std::endl;
    if (!op.empty() && lhs && rhs) {
        if (exprType == TYPE_INT) {
            if (op == "+") return builder.CreateAdd(lhs, rhs, "addtmp");
            if (op == "-") return builder.CreateSub(lhs, rhs, "subtmp");
            if (op == "*") return builder.CreateMul(lhs, rhs, "multmp");
            if (op == "/") return builder.CreateSDiv(lhs, rhs, "divtmp");
            if (op == "%") return builder.CreateSRem(lhs, rhs, "modtmp");
        } else if (exprType == TYPE_FLOAT) {
            if (op == "+") return builder.CreateFAdd(lhs, rhs, "faddtmp");
            if (op == "-") return builder.CreateFSub(lhs, rhs, "fsubtmp");
            if (op == "*") return builder.CreateFMul(lhs, rhs, "fmultmp");
            if (op == "/") return builder.CreateFDiv(lhs, rhs, "fdivtmp");
        }
    } else if (!ident.empty()) {
        Symbol* sym = lookup(ident.c_str());
        if (!insideFunction()) {
            // e.g. "int g = x;" at global scope: a load needs a function to live in
            std::cerr << "ERROR: Cannot read variable " << ident << " outside a function\n";
            return nullptr;
        }
        if (sym && sym->kind == VAR) {
            if (verbose) std::cout << "DEBUG: Loading variable " << ident << std::endl;
            return builder.CreateLoad(getLLVMType(sym->type), sym->value, ident);
        }
        std::cerr << "ERROR: Variable " << ident << " not found or not a variable\n";
    } else if (exprType == TYPE_INT) {
        return llvm::ConstantInt::get(context, llvm::APInt(32, number));
    } else if (exprType == TYPE_FLOAT) {
        return llvm::ConstantFP::get(context, llvm::APFloat(floatNum));
    } else if (exprType == TYPE_BOOL) {
        return llvm::ConstantInt::get(context, llvm::APInt(1, boolVal));
    }
    std::cerr << "ERROR: Invalid expression\n";
    return nullptr;
}

llvm::Value* generateNegateIR(llvm::Value* value) {
    if (verbose) std::cout << "DEBUG: Generating negation\n";
    if (!value) {
        return nullptr;
    }
    // Integers and floats use different instructions (neg = 0 - x, fneg flips the sign bit)
    if (value->getType()->isFloatTy()) {
        return builder.CreateFNeg(value, "negtmp");
    }
    return builder.CreateNeg(value, "negtmp");
}

llvm::Value* generateLogicalIR(const std::string& op, llvm::Value* lhs, llvm::Value* rhs) {
    if (verbose) std::cout << "DEBUG: Generating logical op " << op << std::endl;
    if (!lhs || (op != "!" && !rhs)) {
        return nullptr; // an operand already had an error (e.g. undeclared variable)
    }
    // Like C, any number can be used as true/false (non-zero = true), so turn
    // both sides into bools first: x && flag works even if x is an int.
    lhs = generateConditionIR(lhs);
    if (rhs) {
        rhs = generateConditionIR(rhs);
    }
    if (op == "&&") {
        return builder.CreateAnd(lhs, rhs, "andtmp");
    } else if (op == "||") {
        return builder.CreateOr(lhs, rhs, "ortmp");
    } else if (op == "!") {
        return builder.CreateNot(lhs, "nottmp");
    }
    std::cerr << "ERROR: Invalid logical op " << op << std::endl;
    return nullptr;
}

// C's rule for mixing number types, simplified: when an int meets a float
// in an expression, the int is converted to float first (2 + 0.5 becomes
// 2.0 + 0.5). Returns false if the two types can't be combined (e.g. a bool
// and an int); the operands are then left unchanged.
bool promoteOperandsIR(llvm::Value** lhs, llvm::Value** rhs) {
    llvm::Type* leftType = (*lhs)->getType();
    llvm::Type* rightType = (*rhs)->getType();
    if (leftType == rightType) {
        return true;
    }
    llvm::Type* floatType = llvm::Type::getFloatTy(context);
    if (leftType->isFloatTy() && rightType->isIntegerTy(32)) {
        *rhs = builder.CreateSIToFP(*rhs, floatType, "tofloat");
        return true;
    }
    if (rightType->isFloatTy() && leftType->isIntegerTy(32)) {
        *lhs = builder.CreateSIToFP(*lhs, floatType, "tofloat");
        return true;
    }
    return false;
}

llvm::Value* generateRelationalIR(const std::string& op, llvm::Value* lhs, llvm::Value* rhs) {
    if (verbose) std::cout << "DEBUG: Generating relational op " << op << std::endl;
    if (!lhs || !rhs) {
        return nullptr; // an operand already had an error (e.g. undeclared variable)
    }
    if (!promoteOperandsIR(&lhs, &rhs)) {
        return nullptr; // e.g. comparing a bool with an int
    }
    if (lhs->getType()->isIntegerTy()) { // int, or bool (flag == true)
        if (op == "==") return builder.CreateICmpEQ(lhs, rhs, "eqtmp");
        if (op == "!=") return builder.CreateICmpNE(lhs, rhs, "neqtmp");
        if (op == "<") return builder.CreateICmpSLT(lhs, rhs, "lttmp");
        if (op == ">") return builder.CreateICmpSGT(lhs, rhs, "gttmp");
        if (op == "<=") return builder.CreateICmpSLE(lhs, rhs, "letmp");
        if (op == ">=") return builder.CreateICmpSGE(lhs, rhs, "getmp");
    } else if (lhs->getType()->isFloatTy()) {
        if (op == "==") return builder.CreateFCmpOEQ(lhs, rhs, "feqtmp");
        if (op == "!=") return builder.CreateFCmpONE(lhs, rhs, "fneqtmp");
        if (op == "<") return builder.CreateFCmpOLT(lhs, rhs, "flttmp");
        if (op == ">") return builder.CreateFCmpOGT(lhs, rhs, "fgttmp");
        if (op == "<=") return builder.CreateFCmpOLE(lhs, rhs, "fletmp");
        if (op == ">=") return builder.CreateFCmpOGE(lhs, rhs, "fgetmp");
    }
    std::cerr << "ERROR: Invalid relational op " << op << std::endl;
    return nullptr;
}

void generateAssignIR(const std::string& ident, llvm::Value* value) {
    if (verbose) std::cout << "DEBUG: Generating assign for " << ident << std::endl;
    Symbol* sym = lookup(ident.c_str());
    if (sym && sym->kind == VAR) {
        builder.CreateStore(value, sym->value);
    } else {
        std::cerr << "ERROR: Variable " << ident << " not found or not a variable\n";
    }
}

// Prepare a value to be stored in a variable (or returned) of type target.
// Like C, an int may be used where a float is expected: 3 becomes 3.0, and
// no information is lost. Any other mismatch (e.g. a float into an int)
// is a type error, and nullptr is returned.
llvm::Value* convertForAssignIR(llvm::Value* value, llvm::Type* target) {
    if (!value || !target) {
        return nullptr;
    }
    if (value->getType() == target) {
        return value;
    }
    if (target->isFloatTy() && value->getType()->isIntegerTy(32)) {
        return builder.CreateSIToFP(value, target, "tofloat");
    }
    return nullptr;
}

// return value; (or return; when value is nullptr). Returns false if the
// value doesn't match the function's return type.
bool generateReturnIR(llvm::Value* value) {
    if (verbose) std::cout << "DEBUG: Generating return\n";
    llvm::Type* returnType = builder.GetInsertBlock()->getParent()->getReturnType();
    if (value) {
        value = convertForAssignIR(value, returnType);
        if (!value) {
            return false;
        }
        builder.CreateRet(value);
    } else {
        builder.CreateRetVoid();
    }
    startBlockAfterJump();
    return true;
}

llvm::Value* generateFunctionCallIR(const std::string& name, Param* args) {
    if (verbose) std::cout << "DEBUG: Generating function call for " << name << std::endl;
    llvm::Function* func = module->getFunction(name);
    if (!func) {
        std::cerr << "Error: Function '" << name << "' not found" << std::endl;
        return nullptr;
    }
    if (!insideFunction()) {
        std::cerr << "ERROR: Cannot call function " << name << " outside a function\n";
        return nullptr;
    }
    std::vector<llvm::Value*> argValues;
    Param* current = args;
    while (current) {
        argValues.push_back(current->value);
        current = current->next;
    }
    // A void call produces no value, and LLVM does not allow naming it
    if (func->getReturnType()->isVoidTy()) {
        return builder.CreateCall(func, argValues);
    }
    return builder.CreateCall(func, argValues, name + "_call");
}

void generatePrintfIR(const std::string& format, const std::vector<llvm::Value*>& args) {
    if (verbose) std::cout << "DEBUG: Generating printf with format \"" << format << "\"\n";
    llvm::Function* printfFunc = getPrintfFunction();
    std::vector<llvm::Value*> callArgs;
    callArgs.push_back(builder.CreateGlobalStringPtr(format, "format"));
    for (size_t i = 0; i < args.size(); i++) {
        llvm::Value* arg = args[i];
        // C's rule for variadic functions like printf: a float argument is
        // passed as a double, and small integers (our bool, i1) as an int.
        // Without this, printf reads garbage (e.g. 0.000000 for 1.5).
        if (arg->getType()->isFloatTy()) {
            arg = builder.CreateFPExt(arg, llvm::Type::getDoubleTy(context), "promoted");
        } else if (arg->getType()->isIntegerTy(1)) {
            arg = builder.CreateZExt(arg, llvm::Type::getInt32Ty(context), "promoted");
        }
        callArgs.push_back(arg);
    }
    builder.CreateCall(printfFunc, callArgs);
}

void generateScanfIR(const std::string& ident, SymbolType type) {
    if (verbose) std::cout << "DEBUG: Generating scanf for " << ident << std::endl;
    llvm::Function* scanfFunc = getScanfFunction();
    Symbol* sym = lookup(ident.c_str());
    if (!sym) {
        std::cerr << "ERROR: Variable " << ident << " not found\n";
        return;
    }
    llvm::Value* formatStr;
    if (type == TYPE_INT) {
        formatStr = builder.CreateGlobalStringPtr("%d", "scanf_format");
    } else if (type == TYPE_FLOAT) {
        formatStr = builder.CreateGlobalStringPtr("%f", "scanf_format");
    } else {
        std::cerr << "ERROR: Unsupported type for scanf\n";
        return;
    }
    builder.CreateCall(scanfFunc, {formatStr, sym->value});
}

// Branch instructions need an i1 (true/false). C lets you write if (x) for
// any number, meaning "x is not zero", so convert ints and floats here.
llvm::Value* generateConditionIR(llvm::Value* value) {
    if (!value) {
        return nullptr;
    }
    llvm::Type* type = value->getType();
    if (type->isIntegerTy(1)) {
        return value;
    }
    if (type->isFloatTy()) {
        return builder.CreateFCmpONE(value, llvm::ConstantFP::get(type, 0.0), "tobool");
    }
    return builder.CreateICmpNE(value, llvm::ConstantInt::get(type, 0), "tobool");
}

// If the current block doesn't already end in a return/branch, jump to dest.
// (A branch body that ends with "return" must not get a second terminator.)
static void branchIfOpen(llvm::BasicBlock* dest) {
    if (!builder.GetInsertBlock()->getTerminator()) {
        builder.CreateBr(dest);
    }
}

// Called right after "if (cond)" is parsed, BEFORE the body. Because Bison
// runs actions bottom-up, this is our only chance to set up the blocks so
// that the body's code is generated inside the "then" block.
//
// At this point we don't know yet whether an "else" will follow, so the
// false edge of the branch goes to "merge" for now. If an else shows up,
// generateIfElseIR patches it (this is called backpatching).
IfBlocks* generateIfStartIR(llvm::Value* cond) {
    if (verbose) std::cout << "DEBUG: Generating if start\n";
    if (!cond) {
        return nullptr;
    }
    llvm::Function* func = builder.GetInsertBlock()->getParent();
    llvm::BasicBlock* thenBB = llvm::BasicBlock::Create(context, "then", func);
    // merge is added to the function later, so blocks appear in source order in output.ll
    llvm::BasicBlock* mergeBB = llvm::BasicBlock::Create(context, "merge");

    IfBlocks* blocks = new IfBlocks;
    blocks->condBranch = builder.CreateCondBr(cond, thenBB, mergeBB);
    blocks->mergeBB = mergeBB;
    builder.SetInsertPoint(thenBB);
    return blocks;
}

// Called when "else" is seen: finish the then-body and start the else-body.
void generateIfElseIR(IfBlocks* blocks) {
    if (verbose) std::cout << "DEBUG: Generating else\n";
    if (!blocks) {
        return;
    }
    // The current block is the end of the then-body. It may not be "then"
    // itself if the body contained a nested if.
    branchIfOpen(blocks->mergeBB);

    llvm::Function* func = builder.GetInsertBlock()->getParent();
    llvm::BasicBlock* elseBB = llvm::BasicBlock::Create(context, "else", func);
    blocks->condBranch->setSuccessor(1, elseBB); // backpatch: false edge → else
    builder.SetInsertPoint(elseBB);
}

// Called at the very end of the if statement: both paths meet in "merge".
void generateIfEndIR(IfBlocks* blocks) {
    if (verbose) std::cout << "DEBUG: Generating if end\n";
    if (!blocks) {
        return;
    }
    branchIfOpen(blocks->mergeBB);

    llvm::Function* func = builder.GetInsertBlock()->getParent();
    func->getBasicBlockList().push_back(blocks->mergeBB);
    builder.SetInsertPoint(blocks->mergeBB);
    delete blocks;
}

// Loops use the same idea as if: the parser calls these functions at the
// right moments WHILE it reads the loop, so each piece of code lands in
// the right block. The finished loop looks like:
//
//   loop.cond:  evaluate the condition, br cond ? loop.body : loop.after
//   loop.body:  the body, then br for.step (for) or br loop.cond (while)
//   for.step:   the update (i++), then br loop.cond          (for only)
//   loop.after: code after the loop

// Called before the condition is parsed. The condition gets its own block,
// so jumping back to it re-evaluates the condition on every iteration.
LoopBlocks* generateLoopStartIR() {
    if (verbose) std::cout << "DEBUG: Generating loop start\n";
    llvm::Function* func = builder.GetInsertBlock()->getParent();
    LoopBlocks* loop = new LoopBlocks;
    loop->condBB = llvm::BasicBlock::Create(context, "loop.cond", func);
    loop->bodyBB = nullptr;
    loop->stepBB = nullptr;
    loop->afterBB = nullptr;
    builder.CreateBr(loop->condBB);
    builder.SetInsertPoint(loop->condBB);
    return loop;
}

// Called after the condition is parsed: branch into the body or out of the loop.
// For a for loop, the update (i++) is parsed next, BEFORE the body, even
// though it must run AFTER the body. So we send it to its own for.step block.
void generateLoopCondIR(LoopBlocks* loop, llvm::Value* cond, bool hasStep) {
    if (verbose) std::cout << "DEBUG: Generating loop condition\n";
    llvm::Function* func = builder.GetInsertBlock()->getParent();
    loop->bodyBB = llvm::BasicBlock::Create(context, "loop.body", func);
    if (hasStep) {
        loop->stepBB = llvm::BasicBlock::Create(context, "for.step", func);
    }
    // after is added to the function at the end, so blocks appear in source order
    loop->afterBB = llvm::BasicBlock::Create(context, "loop.after");

    if (!cond) {
        // The condition had an error (already reported); keep the IR well-formed
        cond = llvm::ConstantInt::get(context, llvm::APInt(1, 0));
    }
    builder.CreateCondBr(cond, loop->bodyBB, loop->afterBB);
    builder.SetInsertPoint(hasStep ? loop->stepBB : loop->bodyBB);

    // Inside this loop's body, break leaves the loop and continue starts the
    // next iteration (through the step in a for loop, so i++ still runs)
    breakTargets.push_back(loop->afterBB);
    continueTargets.push_back(hasStep ? loop->stepBB : loop->condBB);
}

// for loops only: the update has been generated in for.step. Jump back to
// the condition from there, then move on to the body.
void generateForStepEndIR(LoopBlocks* loop) {
    if (verbose) std::cout << "DEBUG: Generating for step end\n";
    builder.CreateBr(loop->condBB);
    builder.SetInsertPoint(loop->bodyBB);
}

// Called after the body: go round again (through the step for a for loop),
// then continue with the code after the loop.
void generateLoopEndIR(LoopBlocks* loop) {
    if (verbose) std::cout << "DEBUG: Generating loop end\n";
    branchIfOpen(loop->stepBB ? loop->stepBB : loop->condBB);
    breakTargets.pop_back();
    continueTargets.pop_back();

    llvm::Function* func = builder.GetInsertBlock()->getParent();
    func->getBasicBlockList().push_back(loop->afterBB);
    builder.SetInsertPoint(loop->afterBB);
    delete loop;
}

// break: jump out of the innermost loop or switch.
// Returns false if there is no loop or switch around it.
bool generateBreakIR() {
    if (verbose) std::cout << "DEBUG: Generating break\n";
    if (breakTargets.empty()) {
        return false;
    }
    builder.CreateBr(breakTargets.back());
    startBlockAfterJump();
    return true;
}

// continue: jump to the next iteration of the innermost loop.
// (A switch has no continue target, so continue inside a switch inside a
// loop correctly goes to the loop.) Returns false if there is no loop.
bool generateContinueIR() {
    if (verbose) std::cout << "DEBUG: Generating continue\n";
    if (continueTargets.empty()) {
        return false;
    }
    builder.CreateBr(continueTargets.back());
    startBlockAfterJump();
    return true;
}

// switch
// Case labels appear deep inside the case list, where they can't easily
// reach a value on Bison's stack, so the current switch is kept on this
// stack instead (the back is the innermost switch).
struct SwitchInfo {
    llvm::SwitchInst* sw;      // the switch instruction; cases are added to it
    llvm::BasicBlock* afterBB; // code after the switch (break jumps here)
    bool hasDefault;
};
std::vector<SwitchInfo*> switchStack;

// Called right after "switch (value)". Until a default label appears, the
// switch's default destination is the code after the switch.
void generateSwitchStartIR(llvm::Value* value) {
    if (verbose) std::cout << "DEBUG: Generating switch start\n";
    SwitchInfo* info = new SwitchInfo;
    info->afterBB = llvm::BasicBlock::Create(context, "switch.after");
    info->sw = builder.CreateSwitch(value, info->afterBB);
    info->hasDefault = false;
    switchStack.push_back(info);
    breakTargets.push_back(info->afterBB);
}

// Start a new case block. If the previous case didn't end with break, its
// code falls through into this one, exactly like C.
static void startCaseBlock(llvm::BasicBlock* caseBB) {
    branchIfOpen(caseBB);
    builder.SetInsertPoint(caseBB);
}

// "case value:". Returns 1 if this value was already used in the switch.
int generateCaseIR(int value) {
    if (verbose) std::cout << "DEBUG: Generating case " << value << std::endl;
    SwitchInfo* info = switchStack.back();
    llvm::ConstantInt* caseValue = llvm::ConstantInt::get(context, llvm::APInt(32, value, true));
    if (info->sw->findCaseValue(caseValue) != info->sw->case_default()) {
        return 1;
    }
    llvm::Function* func = builder.GetInsertBlock()->getParent();
    llvm::BasicBlock* caseBB = llvm::BasicBlock::Create(context, "case." + std::to_string(value), func);
    info->sw->addCase(caseValue, caseBB);
    startCaseBlock(caseBB);
    return 0;
}

// "default:". Returns 1 if the switch already has a default.
int generateDefaultCaseIR() {
    if (verbose) std::cout << "DEBUG: Generating default case\n";
    SwitchInfo* info = switchStack.back();
    if (info->hasDefault) {
        return 1;
    }
    llvm::Function* func = builder.GetInsertBlock()->getParent();
    llvm::BasicBlock* defaultBB = llvm::BasicBlock::Create(context, "default", func);
    info->sw->setDefaultDest(defaultBB); // backpatch: was "after the switch"
    info->hasDefault = true;
    startCaseBlock(defaultBB);
    return 0;
}

// Called at the closing brace: the last case falls out of the switch.
void generateSwitchEndIR() {
    if (verbose) std::cout << "DEBUG: Generating switch end\n";
    SwitchInfo* info = switchStack.back();
    branchIfOpen(info->afterBB);
    switchStack.pop_back();
    breakTargets.pop_back();

    llvm::Function* func = builder.GetInsertBlock()->getParent();
    func->getBasicBlockList().push_back(info->afterBB);
    builder.SetInsertPoint(info->afterBB);
    delete info;
}

bool writeIRToFile(const std::string& filename) {
    if (verbose) std::cout << "DEBUG: Writing IR to " << filename << std::endl;
    if (!module) {
        std::cerr << "Error: Module is null" << std::endl;
        return false;
    }
    if (verbose) std::cerr << "Module function count: " << module->size() << std::endl;
    if (llvm::verifyModule(*module, &llvm::errs())) {
        std::cerr << "Module verification failed" << std::endl;
        return false;
    }
    std::error_code EC;
    llvm::raw_fd_ostream out(filename, EC);
    if (EC) {
        std::cerr << "Error opening file " << filename << ": " << EC.message() << std::endl;
        return false;
    }
    module->print(out, nullptr);
    out.close();
    if (verbose) std::cout << "IR written to " << filename << std::endl;
    return true;
}