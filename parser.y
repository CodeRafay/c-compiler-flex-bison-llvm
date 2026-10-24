%code requires {
#include "symbol_table.h"
#include "llvm_ir.h"
}

%{
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "symbol_table.h"
#include "llvm_ir.h"

extern FILE *yyin;
extern int yylineno;

void yyerror(const char *s);
int yylex(void);
SymbolType currentType;
int currentScope = 0;
extern llvm::SwitchInst* currentSwitchInst;
%}

%union {
    int num;
    float fnum;
    char* id;
    char* str;
    SymbolType typeval;
    struct Param* param;
    llvm::Value* llvm_val;
    llvm::BasicBlock* bb;
    void* stmt;
}

%nonassoc THEN
%nonassoc ELSE

%left OR AND
%left EQ NEQ GT GE LE LT
%left PLUS MINUS
%left MULT DIV MOD
%right NOT
%right ASSIGN

%token <num> NUMBER
%token <fnum> FLOATNUMBER
%token <id> IDENTIFIER
%token <str> STRING
%type <llvm_val> expr
%type <llvm_val> init_expr
%type <llvm_val> update_expr
%type <stmt> compound_stmt
%type <stmt> stmt
%type <id> main_or_id
%type <param> parameter_declaration
%type <param> parameter_list
%type <param> parameter_list_opt
%type <param> arg_list
%type <param> arg_list_opt
%type <bb> switch_start
%type <typeval> type_specifier

%token INT FLOAT BOOL VOID RETURN MAIN PRINTF SCANF FOR IF ELSE WHILE SWITCH CASE TRUE FALSE BREAK DEFAULT
%token LE LT GT GE EQ NEQ AND OR NOT INCR DECR COMMA ASSIGN
%token LPAREN RPAREN LBRACE RBRACE LBRACKET RBRACKET COLON SEMI PLUS MINUS MULT DIV MOD

%%

program:
    declaration_or_function_list 
    {
        printf("Expanding rule: program → declaration_or_function_list (line %d)\n", yylineno);
        writeIRToFile("output.ll");
    }
    ;

declaration_or_function_list:
    declaration_or_function_list declaration_or_function 
    { printf("Expanding rule: declaration_or_function_list → declaration_or_function_list declaration_or_function (line %d)\n", yylineno); }
    | declaration_or_function 
    { printf("Expanding rule: declaration_or_function_list → declaration_or_function (line %d)\n", yylineno); }
    ;

declaration_or_function:
    global_declaration 
    | function_definition
    ;

global_declaration:
    type_specifier var_list SEMI 
    { printf("Expanding rule: global_declaration → type_specifier var_list SEMI (line %d)\n", yylineno); }
    ;

function_definition:
    type_specifier main_or_id LPAREN parameter_list_opt RPAREN 
    {
        printf("DEBUG: Entering function_definition for %s, scope=%d\n", $2, currentScope);
        initLLVM("my_module"); // Ensure module is initialized
        currentScope++;
        printf("DEBUG: Incremented scope to %d\n", currentScope);
        // Use $1 (the return type), not currentType: parsing the parameters
        // has already overwritten currentType with the last parameter's type.
        printf("DEBUG: Calling generateFunctionIR for %s\n", $2);
        llvm::Function* func = generateFunctionIR($2, $1, $4, true);
        if (!func) {
            printf("Error: Failed to generate function IR for '%s' (line %d)\n", $2, yylineno);
            YYERROR;
        }
        // Parameters go into the symbol table only AFTER generateFunctionIR,
        // because that is where each one gets its stack slot (alloca).
        // Every later use of the parameter loads from temp->value.
        Param* temp = $4;
        while (temp != NULL) {
            if (temp->name == NULL) {
                fprintf(stderr, "ERROR: Null parameter name in function %s (line %d)\n", $2, yylineno);
                YYERROR;
            }
            printf("DEBUG: Inserting parameter %s, type=%d\n", temp->name, temp->type);
            insertVariable(temp->name, temp->type, currentScope, temp->value);
            temp = temp->next;
        }
        printf("DEBUG: Inserting function %s\n", $2);
        insertFunction($2, $1, $4, 1, func);
        currentScope++;
        printf("DEBUG: Incremented scope to %d\n", currentScope);
        // Start emitting instructions into the function's entry block
        llvm::BasicBlock* entry = &func->getEntryBlock();
        if (!entry->getTerminator()) {
            builder.SetInsertPoint(entry);
        }
    }
    compound_stmt
    {
        printf("Expanding rule: function_definition → type_specifier main_or_id LPAREN parameter_list_opt RPAREN compound_stmt (line %d)\n", yylineno);
        // If the body falls off the end without a return, add one ourselves.
        llvm::BasicBlock* currentBB = builder.GetInsertBlock();
        if (!currentBB->getTerminator()) {
            llvm::Type* retType = currentBB->getParent()->getReturnType();
            if (retType->isVoidTy()) {
                builder.CreateRetVoid();
            } else {
                // Default return value: 0 / 0.0 / false, matching the return type
                builder.CreateRet(llvm::Constant::getNullValue(retType));
            }
        }
        // We are back at global scope, where there is no current block.
        // Clearing the insert point means nothing (like a global variable)
        // can accidentally be emitted into the function we just finished.
        builder.ClearInsertionPoint();
        currentScope -= 2;
        // Parameters live in currentScope + 1; drop them so the next
        // function can reuse the same names.
        exitScope(currentScope + 1);
        printf("DEBUG: Exiting function_definition, scope=%d\n", currentScope);
    }
    | type_specifier main_or_id LPAREN parameter_list_opt RPAREN SEMI
    {
        printf("Expanding rule: function_definition → type_specifier main_or_id LPAREN parameter_list_opt RPAREN SEMI (line %d)\n", yylineno);
        initLLVM("my_module"); // Ensure module is initialized for declarations
        llvm::Function* func = generateFunctionIR($2, $1, $4, false);
        insertFunction($2, $1, $4, 0, func);
    }
    ;

main_or_id:
    MAIN { 
        $$ = strdup("main");
        printf("Expanding rule: main_or_id → MAIN (line %d)\n", yylineno);
    }
    | IDENTIFIER { 
        $$ = strdup($1);
        printf("Expanding rule: main_or_id → IDENTIFIER (line %d)\n", yylineno);
    }
    ;

type_specifier:
    INT { printf("Expanding rule: type_specifier → INT (line %d)\n", yylineno); currentType = TYPE_INT; $$ = TYPE_INT; }
    | FLOAT { printf("Expanding rule: type_specifier → FLOAT (line %d)\n", yylineno); currentType = TYPE_FLOAT; $$ = TYPE_FLOAT; }
    | BOOL { printf("Expanding rule: type_specifier → BOOL (line %d)\n", yylineno); currentType = TYPE_BOOL; $$ = TYPE_BOOL; }
    | VOID { printf("Expanding rule: type_specifier → VOID (line %d)\n", yylineno); currentType = TYPE_VOID; $$ = TYPE_VOID; }
    ;

parameter_list_opt:
    /* empty */ { printf("Expanding rule: parameter_list_opt → /* empty */ (line %d)\n", yylineno); $$ = NULL; }
    | parameter_list { printf("Expanding rule: parameter_list_opt → parameter_list (line %d)\n", yylineno); $$ = $1; }
    ;

parameter_list:
    parameter_declaration { printf("Expanding rule: parameter_list → parameter_declaration (line %d)\n", yylineno); $$ = $1; }
    | parameter_list COMMA parameter_declaration {
        printf("Expanding rule: parameter_list → parameter_list COMMA parameter_declaration (line %d)\n", yylineno);
        Param* temp = $1;
        while (temp->next) temp = temp->next;
        temp->next = $3;
        $$ = $1;
    }
    ;

parameter_declaration:
    type_specifier IDENTIFIER {
        printf("Expanding rule: parameter_declaration → type_specifier IDENTIFIER (line %d)\n", yylineno);
        Param* p = (Param*)malloc(sizeof(Param));
        p->name = strdup($2);
        if (p->name == NULL) {
            fprintf(stderr, "ERROR: Failed to allocate memory for parameter name (line %d)\n", yylineno);
            YYERROR;
        }
        p->type = currentType;
        p->value = nullptr;
        p->next = nullptr;
        $$ = p;
    }
    ;

compound_stmt:
    LBRACE { 
        currentScope++; 
        printf("DEBUG: Entering compound_stmt, scope=%d (line %d)\n", currentScope, yylineno);
    } stmt_list_opt RBRACE { 
        printf("Expanding rule: compound_stmt → LBRACE stmt_list_opt RBRACE (line %d)\n", yylineno);
        // Variables declared inside this block go out of scope here
        exitScope(currentScope);
        currentScope--;
        printf("DEBUG: Exiting compound_stmt, scope=%d\n", currentScope);
        $$ = nullptr;
    }
    ;

stmt_list_opt:
    /* empty */ { printf("Expanding rule: stmt_list_opt → /* empty */ (line %d)\n", yylineno); }
    | stmt_list { printf("Expanding rule: stmt_list_opt → stmt_list (line %d)\n", yylineno); }
    ;

stmt_list:
    stmt_list stmt { printf("Expanding rule: stmt_list → stmt_list stmt (line %d)\n", yylineno); }
    | stmt { printf("Expanding rule: stmt_list → stmt (line %d)\n", yylineno); }
    ;

stmt:
    IDENTIFIER ASSIGN expr SEMI {
        printf("Expanding rule: stmt → IDENTIFIER ASSIGN expr SEMI (line %d)\n", yylineno);
        Symbol* lhs = lookup($1);
        if (!lhs) {
            printf("Semantic Error: Variable '%s' not declared (line %d)\n", $1, yylineno);
        } else {
            if ($3 && lhs->type != ($3->getType()->isIntegerTy(32) ? TYPE_INT : ($3->getType()->isFloatTy() ? TYPE_FLOAT : TYPE_BOOL))) {
                printf("Type Error: Cannot assign incompatible type to '%s' (line %d)\n", $1, yylineno);
            }
            generateAssignIR($1, $3);
        }
        $$ = nullptr;
    }
    | IDENTIFIER INCR SEMI {
        printf("Expanding rule: stmt → IDENTIFIER INCR SEMI (line %d)\n", yylineno);
        Symbol* sym = lookup($1);
        if (!sym) {
            printf("Semantic Error: Variable '%s' not declared (line %d)\n", $1, yylineno);
        } else {
            llvm::Value* val = builder.CreateLoad(getLLVMType(sym->type), sym->value, $1);
            llvm::Value* inc = builder.CreateAdd(val, llvm::ConstantInt::get(context, llvm::APInt(32, 1)), "inctmp");
            builder.CreateStore(inc, sym->value);
        }
        $$ = nullptr;
    }
    | IDENTIFIER DECR SEMI {
        printf("Expanding rule: stmt → IDENTIFIER DECR SEMI (line %d)\n", yylineno);
        Symbol* sym = lookup($1);
        if (!sym) {
            printf("Semantic Error: Variable '%s' not declared (line %d)\n", $1, yylineno);
        } else {
            llvm::Value* val = builder.CreateLoad(getLLVMType(sym->type), sym->value, $1);
            llvm::Value* dec = builder.CreateSub(val, llvm::ConstantInt::get(context, llvm::APInt(32, 1)), "dectmp");
            builder.CreateStore(dec, sym->value);
        }
        $$ = nullptr;
    }
    | INCR IDENTIFIER SEMI {
        printf("Expanding rule: stmt → INCR IDENTIFIER SEMI (line %d)\n", yylineno);
        Symbol* sym = lookup($2);
        if (!sym) {
            printf("Semantic Error: Variable '%s' not declared (line %d)\n", $2, yylineno);
        } else {
            llvm::Value* val = builder.CreateLoad(getLLVMType(sym->type), sym->value, $2);
            llvm::Value* inc = builder.CreateAdd(val, llvm::ConstantInt::get(context, llvm::APInt(32, 1)), "inctmp");
            builder.CreateStore(inc, sym->value);
        }
        $$ = nullptr;
    }
    | DECR IDENTIFIER SEMI {
        printf("Expanding rule: stmt → DECR IDENTIFIER SEMI (line %d)\n", yylineno);
        Symbol* sym = lookup($2);
        if (!sym) {
            printf("Semantic Error: Variable '%s' not declared (line %d)\n", $2, yylineno);
        } else {
            llvm::Value* val = builder.CreateLoad(getLLVMType(sym->type), sym->value, $2);
            llvm::Value* dec = builder.CreateSub(val, llvm::ConstantInt::get(context, llvm::APInt(32, 1)), "dectmp");
            builder.CreateStore(dec, sym->value);
        }
        $$ = nullptr;
    }
    | IDENTIFIER LPAREN arg_list_opt RPAREN SEMI {
        printf("Expanding rule: stmt → IDENTIFIER LPAREN arg_list_opt RPAREN SEMI (line %d)\n", yylineno);
        if (!checkFunctionCallArgs($1, $3)) {
            printf("Semantic Error: Invalid arguments for function '%s' (line %d)\n", $1, yylineno);
        } else {
            generateFunctionCallIR($1, $3);
        }
        $$ = nullptr;
    }
    | PRINTF LPAREN arg_list RPAREN SEMI {
        printf("Expanding rule: stmt → PRINTF LPAREN arg_list RPAREN SEMI (line %d)\n", yylineno);
        Param* args = $3;
        if (args && args->type == TYPE_INT) {
            generatePrintfIR(args->value, "%d\n");
        } else if (args && args->type == TYPE_FLOAT) {
            generatePrintfIR(args->value, "%f\n");
        } else if (args && args->type == TYPE_BOOL) {
            generatePrintfIR(args->value, "%d\n");
        }
        $$ = nullptr;
    }
    | SCANF LPAREN IDENTIFIER RPAREN SEMI {
        printf("Expanding rule: stmt → SCANF LPAREN IDENTIFIER RPAREN SEMI (line %d)\n", yylineno);
        Symbol* sym = lookup($3);
        if (!sym) {
            printf("Semantic Error: Variable '%s' not declared (line %d)\n", $3, yylineno);
        } else {
            generateScanfIR($3, sym->type);
        }
        $$ = nullptr;
    }
    |  FOR LPAREN init_expr SEMI expr SEMI update_expr RPAREN compound_stmt {
    printf("Expanding rule: stmt → FOR (...) (line %d)\n", yylineno);
    llvm::BasicBlock* prevInsert = builder.GetInsertBlock();
    // Generate loop structure, get afterBB
    llvm::BasicBlock* afterLoopBB = generateForLoopIR($3, $5, $7);
    // Process compound_stmt (loop body) with current insert point (bodyBB)
    // After compound_stmt, set insert point to afterLoopBB for subsequent statements
    builder.SetInsertPoint(afterLoopBB);
    $$ = nullptr;
    }
    | WHILE LPAREN expr RPAREN compound_stmt {
        printf("Expanding rule: stmt → WHILE LPAREN expr RPAREN compound_stmt (line %d)\n", yylineno);
        generateWhileLoopIR($3);
        $$ = nullptr;
    }
    | IF LPAREN expr RPAREN compound_stmt %prec THEN {
        printf("Expanding rule: stmt → IF LPAREN expr RPAREN compound_stmt (line %d)\n", yylineno);
        if (!$3) {
            printf("Semantic Error: Invalid condition in if statement (line %d)\n", yylineno);
            YYERROR;
        }
        llvm::BasicBlock* prevInsert = builder.GetInsertBlock();
        generateIfStmtIR($3, nullptr);
        builder.SetInsertPoint(thenBB);
        $<stmt>5 = nullptr; // Force re-evaluation of then compound_stmt
        finalizeIfStmtIR(nullptr); // Finalize then block
        builder.SetInsertPoint(mergeBB);
        thenBB = nullptr;
        mergeBB = nullptr;
        $$ = nullptr;
        builder.SetInsertPoint(prevInsert);
    }
    | IF LPAREN expr RPAREN compound_stmt ELSE compound_stmt {
        printf("Expanding rule: stmt → IF LPAREN expr RPAREN compound_stmt ELSE compound_stmt (line %d)\n", yylineno);
        if (!$3) {
            printf("Semantic Error: Invalid condition in if statement (line %d)\n", yylineno);
            YYERROR;
        }
        llvm::BasicBlock* prevInsert = builder.GetInsertBlock();
        generateIfStmtIR($3, (void*)1);
        builder.SetInsertPoint(thenBB);
        $<stmt>5 = nullptr; // Force re-evaluation of then compound_stmt
        builder.SetInsertPoint(elseBB);
        $<stmt>7 = nullptr; // Force re-evaluation of else compound_stmt
        finalizeIfStmtIR((void*)1); // Finalize then and else blocks
        builder.SetInsertPoint(mergeBB);
        thenBB = nullptr;
        elseBB = nullptr;
        mergeBB = nullptr;
        $$ = nullptr;
        builder.SetInsertPoint(prevInsert);
    }
    | RETURN expr SEMI {
        printf("Expanding rule: stmt → RETURN expr SEMI (line %d)\n", yylineno);
        if (!$2) {
            printf("Semantic Error: Invalid return expression (line %d)\n", yylineno);
            YYERROR;
        }
        printf("Generating return for expr at %p\n", $2);
        generateReturnIR($2);
        $$ = nullptr;
    }
    | switch_start case_list RBRACE {
        printf("Expanding rule: stmt → SWITCH LPAREN expr RPAREN LBRACE case_list RBRACE (line %d)\n", yylineno);
        if (afterSwitchBB) {
            // Insert point is already set to switch_cont in switch_start
            builder.SetInsertPoint($<bb>1); // Ensure insert point is switch_cont
        } else {
            printf("Error: No after_switch block for switch statement (line %d)\n", yylineno);
        }
        currentSwitchInst = nullptr;
        afterSwitchBB = nullptr;
        $$ = nullptr;
    }
    | declaration SEMI { printf("Expanding rule: stmt → declaration SEMI (line %d)\n", yylineno); $$ = nullptr; }
    ;

switch_start:
    SWITCH LPAREN expr RPAREN LBRACE {
        printf("Expanding rule: switch start → SWITCH LPAREN expr RPAREN LBRACE (line %d)\n", yylineno);
        if (!$3) {
            printf("Semantic Error: Invalid switch expression (line %d)\n", yylineno);
            YYERROR;
        }
        generateSwitchIR($3);
        // Create a continuation block to ensure proper control flow
        llvm::Function* func = builder.GetInsertBlock()->getParent();
        llvm::BasicBlock* contBB = llvm::BasicBlock::Create(context, "switch_cont", func);
        // Update afterSwitchBB to branch to contBB
        builder.SetInsertPoint(afterSwitchBB);
        builder.CreateBr(contBB);
        builder.SetInsertPoint(contBB);
        $$ = contBB; // Store contBB for later use
    }
    ;

init_expr:
    declaration {
        printf("Expanding rule: init_expr → declaration (line %d)\n", yylineno);
        $$ = nullptr;
    }
    | IDENTIFIER ASSIGN expr {
        printf("Expanding rule: init_expr → IDENTIFIER ASSIGN expr (line %d)\n", yylineno);
        Symbol* lhs = lookup($1);
        if (!lhs) {
            printf("Semantic Error: Variable '%s' not declared (line %d)\n", $1, yylineno);
        } else {
            generateAssignIR($1, $3);
            $$ = $3;
        }
    }
    ;

update_expr:
    IDENTIFIER INCR {
        printf("Expanding rule: update_expr → IDENTIFIER INCR (line %d)\n", yylineno);
        Symbol* sym = lookup($1);
        if (!sym) {
            printf("Semantic Error: Variable '%s' not declared (line %d)\n", $1, yylineno);
            $$ = nullptr;
        } else {
            llvm::Value* val = builder.CreateLoad(getLLVMType(sym->type), sym->value, $1);
            llvm::Value* inc = builder.CreateAdd(val, llvm::ConstantInt::get(context, llvm::APInt(32, 1)), "inctmp");
            builder.CreateStore(inc, sym->value);
            $$ = inc;
        }
    }
    | IDENTIFIER DECR {
        printf("Expanding rule: update_expr → vestitiDECR (line %d)\n", yylineno);
        Symbol* sym = lookup($1);
        if (!sym) {
            printf("Semantic Error: Variable '%s' not declared (line %d)\n", $1, yylineno);
            $$ = nullptr;
        } else {
            llvm::Value* val = builder.CreateLoad(getLLVMType(sym->type), sym->value, $1);
            llvm::Value* dec = builder.CreateSub(val, llvm::ConstantInt::get(context, llvm::APInt(32, 1)), "dectmp");
            builder.CreateStore(dec, sym->value);
            $$ = dec;
        }
    }
    | IDENTIFIER ASSIGN expr {
        printf("Expanding rule: update_expr → IDENTIFIER ASSIGN expr (line %d)\n", yylineno);
        Symbol* lhs = lookup($1);
        if (!lhs) {
            printf("Semantic Error: Variable '%s' not declared (line %d)\n", $1, yylineno);
            $$ = nullptr;
        } else {
            generateAssignIR($1, $3);
            $$ = $3;
        }
    }
    ;

declaration:
    type_specifier var_list { printf("Expanding rule: declaration → type_specifier var_list (line %d)\n", yylineno); }
    ;

var_list:
    var_decl { printf("Expanding rule: var_list → var_decl (line %d)\n", yylineno); }
    | var_list COMMA var_decl { printf("Expanding rule: var_list → var_list COMMA var_decl (line %d)\n", yylineno); }
    ;

var_decl:
    IDENTIFIER {
        printf("Expanding rule: var_decl → IDENTIFIER (line %d)\n", yylineno);
        llvm::Value* alloc = generateVariableDeclIR($1, currentType, currentScope);
        if (!alloc) {
            printf("Error: Failed to generate variable declaration for '%s' (line %d)\n", $1, yylineno);
            YYERROR;
        }
        Symbol* sym = lookup($1);
        if (sym && sym->scope == currentScope && sym->kind == VAR) {
            printf("Semantic Error: Variable '%s' redeclared in scope %d (line %d)\n", $1, currentScope, yylineno);
            YYERROR;
        }
        insertVariable($1, currentType, currentScope, alloc);
    }
    | IDENTIFIER ASSIGN expr {
        printf("Expanding rule: var_decl → IDENTIFIER ASSIGN expr (line %d)\n", yylineno);
        llvm::Value* alloc = generateVariableDeclIR($1, currentType, currentScope);
        if (!alloc) {
            printf("Error: Failed to generate variable declaration for '%s' (line %d)\n", $1, yylineno);
            YYERROR;
        }
        Symbol* sym = lookup($1);
        if (sym && sym->scope == currentScope && sym->kind == VAR) {
            printf("Semantic Error: Variable '%s' redeclared in scope %d (line %d)\n", $1, currentScope, yylineno);
            YYERROR;
        }
        insertVariable($1, currentType, currentScope, alloc);
        if (!$3) {
            printf("Error: Expression for assignment to '%s' is invalid (line %d)\n", $1, yylineno);
            YYERROR;
        }
        if ($3->getType()->isIntegerTy(32) ? TYPE_INT : ($3->getType()->isFloatTy() ? TYPE_FLOAT : TYPE_BOOL) != currentType) {
            printf("Type Error: Cannot assign incompatible type to '%s' (line %d)\n", $1, yylineno);
        }
        if (currentScope == 0) {
            // Global: no code runs at global scope, so instead of a store
            // the value becomes the global's initial value.
            if (!setGlobalInitializerIR(alloc, $3)) {
                printf("Semantic Error: Global variable '%s' must be initialized with a constant of the same type (line %d)\n", $1, yylineno);
            }
        } else {
            generateAssignIR($1, $3);
        }
    }
    | IDENTIFIER LBRACKET NUMBER RBRACKET {
        printf("Expanding rule: var_decl → IDENTIFIER LBRACKET NUMBER RBRACKET (line %d)\n", yylineno);
        llvm::Value* alloc = generateArrayDeclIR($1, currentType, $3, currentScope);
        if (!alloc) {
            printf("Error: Failed to generate array declaration for '%s' (line %d)\n", $1, yylineno);
            YYERROR;
        }
        insertVariable($1, currentType, currentScope, alloc);
    }
    ;

case_list:
    case_list case_stmt { printf("Expanding rule: case_list → case_list case_stmt (line %d)\n", yylineno); }
    | case_stmt { printf("Expanding rule: case_list → case_stmt (line %d)\n", yylineno); }
    ;

case_stmt:
    CASE NUMBER COLON stmt_list BREAK SEMI {
        printf("Expanding rule: case_stmt → CASE NUMBER COLON stmt_list BREAK SEMI (line %d)\n", yylineno);
        generateCaseIR($2);
        if (afterSwitchBB) {
            builder.CreateBr(afterSwitchBB);
        } else {
            printf("Error: No after_switch block for case %d (line %d)\n", $2, yylineno);
        }
    }
    | DEFAULT COLON stmt_list BREAK SEMI {
        printf("Expanding rule: case_stmt → DEFAULT COLON stmt_list BREAK SEMI (line %d)\n", yylineno);
        generateDefaultCaseIR();
        if (afterSwitchBB) {
            builder.CreateBr(afterSwitchBB);
        } else {
            printf("Error: No after_switch block for default case (line %d)\n", yylineno);
        }
    }
    | DEFAULT COLON stmt_list {
        printf("Expanding rule: case_stmt → DEFAULT COLON stmt_list (line %d)\n", yylineno);
        generateDefaultCaseIR();
        if (afterSwitchBB) {
            builder.CreateBr(afterSwitchBB);
        } else {
            printf("Error: No after_switch block for default case (line %d)\n", yylineno);
        }
    }
    ;

expr:
    expr PLUS expr {
        printf("Expanding rule: expr → expr PLUS expr (line %d)\n", yylineno);
        if ($1 && $3 && $1->getType() != $3->getType()) {
            printf("Type Error: Mismatched types in addition at line %d\n", yylineno);
        }
        $$ = generateExprIR($1 && $1->getType()->isIntegerTy(32) ? TYPE_INT : TYPE_FLOAT, "+", $1, $3, "", 0, 0.0, false);
    }
    | expr MINUS expr {
        printf("Expanding rule: expr → expr MINUS expr (line %d)\n", yylineno);
        if ($1 && $3 && $1->getType() != $3->getType()) {
            printf("Type Error: Mismatched types in subtraction at line %d\n", yylineno);
        }
        $$ = generateExprIR($1 && $1->getType()->isIntegerTy(32) ? TYPE_INT : TYPE_FLOAT, "-", $1, $3, "", 0, 0.0, false);
    }
    | expr MULT expr {
        printf("Expanding rule: expr → expr MULT expr (line %d)\n", yylineno);
        if ($1 && $3 && $1->getType() != $3->getType()) {
            printf("Type Error: Mismatched types in multiplication at line %d\n", yylineno);
        }
        $$ = generateExprIR($1 && $1->getType()->isIntegerTy(32) ? TYPE_INT : TYPE_FLOAT, "*", $1, $3, "", 0, 0.0, false);
    }
    | expr DIV expr {
        printf("Expanding rule: expr → expr DIV expr (line %d)\n", yylineno);
        if ($1 && $3 && $1->getType() != $3->getType()) {
            printf("Type Error: Mismatched types in division at line %d\n", yylineno);
        }
        $$ = generateExprIR($1 && $1->getType()->isIntegerTy(32) ? TYPE_INT : TYPE_FLOAT, "/", $1, $3, "", 0, 0.0, false);
    }
    | expr MOD expr {
        printf("Expanding rule: expr → expr MOD expr (line %d)\n", yylineno);
        if ($1 && $3 && $1->getType() != $3->getType()) {
            printf("Type Error: Mismatched types in modulo at line %d\n", yylineno);
        }
        $$ = generateExprIR(TYPE_INT, "%", $1, $3, "", 0, 0.0, false);
    }
    | expr AND expr {
        printf("Expanding rule: expr → expr AND expr (line %d)\n", yylineno);
        $$ = generateLogicalIR("&&", $1, $3);
    }
    | expr OR expr {
        printf("Expanding rule: expr → expr OR expr (line %d)\n", yylineno);
        $$ = generateLogicalIR("||", $1, $3);
    }
    | NOT expr {
        printf("Expanding rule: expr → NOT expr (line %d)\n", yylineno);
        $$ = generateLogicalIR("!", $2, nullptr);
    }
    | MINUS expr %prec NOT {
        // Unary minus (-x). %prec NOT gives it the same high precedence as
        // '!', so -a * b means (-a) * b, not -(a * b).
        printf("Expanding rule: expr → MINUS expr (line %d)\n", yylineno);
        $$ = generateNegateIR($2);
    }
    | expr EQ expr {
        printf("Expanding rule: expr → expr EQ expr (line %d)\n", yylineno);
        $$ = generateRelationalIR("==", $1, $3);
    }
    | expr NEQ expr {
        printf("Expanding rule: expr → expr NEQ expr (line %d)\n", yylineno);
        $$ = generateRelationalIR("!=", $1, $3);
    }
    | expr LT expr {
        printf("Expanding rule: expr → expr LT expr (line %d)\n", yylineno);
        $$ = generateRelationalIR("<", $1, $3);
    }
    | expr GT expr {
        printf("Expanding rule: expr → expr GT expr (line %d)\n", yylineno);
        $$ = generateRelationalIR(">", $1, $3);
    }
    | expr LE expr {
        printf("Expanding rule: expr → expr LE expr (line %d)\n", yylineno);
        $$ = generateRelationalIR("<=", $1, $3);
    }
    | expr GE expr {
        printf("Expanding rule: expr → expr GE expr (line %d)\n", yylineno);
        $$ = generateRelationalIR(">=", $1, $3);
    }
    | NUMBER {
        printf("Expanding rule: expr → NUMBER (line %d)\n", yylineno);
        $$ = generateExprIR(TYPE_INT, "", nullptr, nullptr, "", $1, 0.0, false);
    }
    | FLOATNUMBER {
        printf("Expanding rule: expr → FLOATNUMBER (line %d)\n", yylineno);
        $$ = generateExprIR(TYPE_FLOAT, "", nullptr, nullptr, "", 0, $1, false);
    }
    | TRUE {
        printf("Expanding rule: expr → TRUE (line %d)\n", yylineno);
        $$ = generateExprIR(TYPE_BOOL, "", nullptr, nullptr, "", 0, 0.0, true);
    }
    | FALSE {
        printf("Expanding rule: expr → FALSE (line %d)\n", yylineno);
        $$ = generateExprIR(TYPE_BOOL, "", nullptr, nullptr, "", 0, 0.0, false);
    }
    | IDENTIFIER {
        printf("Expanding rule: expr → IDENTIFIER (line %d)\n", yylineno);
        Symbol* sym = lookup($1);
        if (!sym) {
            printf("Semantic Error: Variable '%s' not declared (line %d)\n", $1, yylineno);
            $$ = nullptr;
        } else if (sym->kind == VAR) {
            $$ = generateExprIR(sym->type, "", nullptr, nullptr, $1, 0, 0.0, false);
        } else {
            $$ = nullptr; // Functions handled by function call rule
        }
    }
    | IDENTIFIER LPAREN arg_list_opt RPAREN {
        printf("Expanding rule: expr → IDENTIFIER LPAREN arg_list_opt RPAREN (line %d)\n", yylineno);
        if (!checkFunctionCallArgs($1, $3)) {
            printf("Semantic Error: Invalid arguments for function '%s' (line %d)\n", $1, yylineno);
            $$ = nullptr;
        } else {
            $$ = generateFunctionCallIR($1, $3);
        }
    }
    | LPAREN expr RPAREN {
        printf("Expanding rule: expr → LPAREN expr RPAREN (line %d)\n", yylineno);
        $$ = $2;
    }
    ;

arg_list_opt:
    /* empty */ { printf("Expanding rule: arg_list_opt → /* empty */ (line %d)\n", yylineno); $$ = NULL; }
    | arg_list { printf("Expanding rule: arg_list_opt → arg_list (line %d)\n", yylineno); $$ = $1; }
    ;

arg_list:
    expr {
        printf("Expanding rule: arg_list → expr (line %d)\n", yylineno);
        Param* p = (Param*)malloc(sizeof(Param));
        p->type = $1 ? ($1->getType()->isIntegerTy(32) ? TYPE_INT : ($1->getType()->isFloatTy() ? TYPE_FLOAT : TYPE_BOOL)) : TYPE_INT;
        p->name = nullptr;
        p->value = $1;
        p->next = nullptr;
        $$ = p;
    }
    | arg_list COMMA expr {
        printf("Expanding rule: arg_list → arg_list COMMA expr (line %d)\n", yylineno);
        Param* p = (Param*)malloc(sizeof(Param));
        p->type = $3 ? ($3->getType()->isIntegerTy(32) ? TYPE_INT : ($3->getType()->isFloatTy() ? TYPE_FLOAT : TYPE_BOOL)) : TYPE_INT;
        p->name = nullptr;
        p->value = $3;
        p->next = nullptr;
        Param* temp = $1;
        while (temp->next) temp = temp->next;
        temp->next = p;
        $$ = $1;
    }
    ;

%%

void yyerror(const char *s) {
    fprintf(stderr, "Syntax Error: %s at line %d\n", s, yylineno);
}

int main(int argc, char *argv[]) {
    if (argc != 2) {
        fprintf(stderr, "Usage: %s <filename>\n", argv[0]);
        return 1;
    }
    FILE *file = fopen(argv[1], "r");
    if (!file) {
        perror("Error opening file");
        return 1;
    }
    yyin = file;
    // Create the module up front: a file may start with global variables,
    // which need the module before any function has been seen.
    initLLVM("my_module");
    initSymbolTable();
    int result = yyparse();
    fclose(file);
    if (result == 0) {
        printf("Parsing successful!\n");
    } else {
        printf("Parsing failed with errors.\n");
    }
    printSymbolTable();
    freeSymbolTable();
    return result;

    // HOW TO RUN ??
    //  make clean
    //  make
    //  ./compiler testCaseExamples/test.c
    //  llvm-as output.ll -o output.bc
    //  lli output.bc
    //  echo $?
}
