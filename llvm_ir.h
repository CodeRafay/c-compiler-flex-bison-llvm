#ifndef LLVM_IR_H
#define LLVM_IR_H

#include <llvm/IR/Module.h>
#include <llvm/IR/IRBuilder.h>
#include <llvm/IR/LLVMContext.h>
#include <string>
#include "symbol_table.h"

// The blocks of one if statement, carried on Bison's value stack from
// "if (cond)" to the end of the statement (so nested ifs don't clash).
struct IfBlocks {
    llvm::BranchInst* condBranch; // the conditional branch, patched if an else appears
    llvm::BasicBlock* mergeBB;    // where both paths continue afterwards
};

// The blocks of one while/for loop, carried on Bison's value stack like IfBlocks
struct LoopBlocks {
    llvm::BasicBlock* condBB;  // evaluates the condition (jumped back to every iteration)
    llvm::BasicBlock* bodyBB;  // the loop body
    llvm::BasicBlock* stepBB;  // for loops: the update (i++); nullptr for while
    llvm::BasicBlock* afterBB; // code after the loop
};

#ifdef __cplusplus
extern "C" {
#endif

extern llvm::LLVMContext context;
extern llvm::Module* module;
extern llvm::IRBuilder<> builder;

void initLLVM(const std::string& moduleName);
llvm::Type* getLLVMType(SymbolType type);
llvm::Function* generateFunctionIR(const std::string& name, SymbolType returnType, Param* params, bool isDefined);
llvm::Value* generateVariableDeclIR(const std::string& name, SymbolType type, int scope);
bool setGlobalInitializerIR(llvm::Value* global, llvm::Value* value);
bool insideFunction();
llvm::Value* generateArrayDeclIR(const std::string& name, SymbolType type, int size, int scope);
llvm::Value* getArrayElementPtrIR(llvm::Value* array, SymbolType elemType, int size, llvm::Value* index);
llvm::Value* generateArrayLoadIR(llvm::Value* array, SymbolType elemType, int size, llvm::Value* index);
void generateArrayStoreIR(llvm::Value* array, SymbolType elemType, int size, llvm::Value* index, llvm::Value* value);
llvm::Value* generateExprIR(SymbolType exprType, const std::string& op, llvm::Value* lhs, llvm::Value* rhs, const std::string& ident, int number, float floatNum, bool boolVal);
llvm::Value* generateNegateIR(llvm::Value* value);
llvm::Value* generateLogicalIR(const std::string& op, llvm::Value* lhs, llvm::Value* rhs);
llvm::Value* generateRelationalIR(const std::string& op, llvm::Value* lhs, llvm::Value* rhs);
void generateAssignIR(const std::string& ident, llvm::Value* value);
void generateReturnIR(llvm::Value* value);
llvm::Value* generateFunctionCallIR(const std::string& name, Param* args);
void generatePrintfIR(const std::string& format, const std::vector<llvm::Value*>& args);
void generateScanfIR(const std::string& ident, SymbolType type);
LoopBlocks* generateLoopStartIR();
void generateLoopCondIR(LoopBlocks* loop, llvm::Value* cond, bool hasStep);
void generateForStepEndIR(LoopBlocks* loop);
void generateLoopEndIR(LoopBlocks* loop);
llvm::Value* generateConditionIR(llvm::Value* value);
IfBlocks* generateIfStartIR(llvm::Value* cond);
void generateIfElseIR(IfBlocks* blocks);
void generateIfEndIR(IfBlocks* blocks);
void generateSwitchStartIR(llvm::Value* value);
int generateCaseIR(int value);
int generateDefaultCaseIR();
void generateSwitchEndIR();
bool generateBreakIR();
bool generateContinueIR();
bool writeIRToFile(const std::string& filename);

#ifdef __cplusplus
}
#endif

#endif