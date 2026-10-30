%code requires {
#include "symbol_table.h"
#include "llvm_ir.h"
}

%{
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdarg.h>
#include "symbol_table.h"
#include "llvm_ir.h"

extern FILE *yyin;
extern int yylineno;

void yyerror(const char *s);
int yylex(void);
Symbol* checkArrayAccess(const char* name, llvm::Value* index);
void emitPrintf(const char* quoted, Param* args);
void reportError(const char* format, ...);
int errorCount = 0; // semantic/type errors seen so far; any error = failed compile
SymbolType currentType;
int currentScope = 0;
%}

%union {
    int num;
    float fnum;
    char* id;
    char* str;
    SymbolType typeval;
    struct Param* param;
    llvm::Value* llvm_val;
    void* stmt;
    struct IfBlocks* ifblocks;
    struct LoopBlocks* loop;
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
%type <typeval> type_specifier
%type <ifblocks> if_head

%token INT FLOAT BOOL VOID RETURN MAIN PRINTF SCANF FOR IF ELSE WHILE SWITCH CASE TRUE FALSE BREAK CONTINUE DEFAULT
%token LE LT GT GE EQ NEQ AND OR NOT INCR DECR COMMA ASSIGN
%token LPAREN RPAREN LBRACE RBRACE LBRACKET RBRACKET COLON SEMI PLUS MINUS MULT DIV MOD

%%

program:
    declaration_or_function_list 
    {
        printf("Expanding rule: program → declaration_or_function_list (line %d)\n", yylineno);
        // The IR is written by main() once we know there were no errors
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
        // A prototype may leave parameter names out (int add(int, int);),
        // but a definition can't: the body has no way to refer to them.
        int paramIndex = 1;
        for (Param* p = $4; p != NULL; p = p->next, paramIndex++) {
            if (p->name == NULL) {
                reportError("Semantic Error: Parameter %d of '%s' needs a name in a function definition (line %d)\n", paramIndex, $2, yylineno);
                YYERROR;
            }
        }
        // Use $1 (the return type), not currentType: parsing the parameters
        // has already overwritten currentType with the last parameter's type.
        printf("DEBUG: Calling generateFunctionIR for %s\n", $2);
        llvm::Function* func = generateFunctionIR($2, $1, $4, true);
        if (!func) {
            reportError("Error: Failed to generate function IR for '%s' (line %d)\n", $2, yylineno);
            YYERROR;
        }
        // Parameters go into the symbol table only AFTER generateFunctionIR,
        // because that is where each one gets its stack slot (alloca).
        // Every later use of the parameter loads from temp->value.
        Param* temp = $4;
        while (temp != NULL) {
            printf("DEBUG: Inserting parameter %s, type=%d\n", temp->name, temp->type);
            if (!insertVariable(temp->name, temp->type, currentScope, temp->value, 0)) {
                reportError("Semantic Error: Duplicate parameter '%s' in function '%s' (line %d)\n", temp->name, $2, yylineno);
                YYERROR;
            }
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
    | type_specifier {
        // Unnamed parameter, only allowed in prototypes: int add(int, int);
        printf("Expanding rule: parameter_declaration → type_specifier (line %d)\n", yylineno);
        Param* p = (Param*)malloc(sizeof(Param));
        p->name = NULL;
        p->type = $1;
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
            reportError("Semantic Error: Variable '%s' not declared (line %d)\n", $1, yylineno);
        } else if (lhs->arraySize > 0) {
            reportError("Semantic Error: Cannot assign to array '%s' as a whole; assign an element, e.g. %s[0] = ... (line %d)\n", $1, $1, yylineno);
        } else {
            if ($3 && lhs->type != ($3->getType()->isIntegerTy(32) ? TYPE_INT : ($3->getType()->isFloatTy() ? TYPE_FLOAT : TYPE_BOOL))) {
                reportError("Type Error: Cannot assign incompatible type to '%s' (line %d)\n", $1, yylineno);
            }
            generateAssignIR($1, $3);
        }
        $$ = nullptr;
    }
    | IDENTIFIER LBRACKET expr RBRACKET ASSIGN expr SEMI {
        printf("Expanding rule: stmt → IDENTIFIER LBRACKET expr RBRACKET ASSIGN expr SEMI (line %d)\n", yylineno);
        Symbol* sym = checkArrayAccess($1, $3);
        if (sym && $6) {
            // sym->type is the element type (int a[5] → TYPE_INT)
            if (sym->type != ($6->getType()->isIntegerTy(32) ? TYPE_INT : ($6->getType()->isFloatTy() ? TYPE_FLOAT : TYPE_BOOL))) {
                reportError("Type Error: Cannot assign incompatible type to element of '%s' (line %d)\n", $1, yylineno);
            } else {
                generateArrayStoreIR(sym->value, sym->type, sym->arraySize, $3, $6);
            }
        }
        $$ = nullptr;
    }
    | IDENTIFIER INCR SEMI {
        printf("Expanding rule: stmt → IDENTIFIER INCR SEMI (line %d)\n", yylineno);
        Symbol* sym = lookup($1);
        if (!sym) {
            reportError("Semantic Error: Variable '%s' not declared (line %d)\n", $1, yylineno);
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
            reportError("Semantic Error: Variable '%s' not declared (line %d)\n", $1, yylineno);
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
            reportError("Semantic Error: Variable '%s' not declared (line %d)\n", $2, yylineno);
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
            reportError("Semantic Error: Variable '%s' not declared (line %d)\n", $2, yylineno);
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
            reportError("Semantic Error: Invalid arguments for function '%s' (line %d)\n", $1, yylineno);
        } else {
            generateFunctionCallIR($1, $3);
        }
        $$ = nullptr;
    }
    | PRINTF LPAREN arg_list RPAREN SEMI {
        printf("Expanding rule: stmt → PRINTF LPAREN arg_list RPAREN SEMI (line %d)\n", yylineno);
        emitPrintf(NULL, $3);
        $$ = nullptr;
    }
    | PRINTF LPAREN STRING RPAREN SEMI {
        printf("Expanding rule: stmt → PRINTF LPAREN STRING RPAREN SEMI (line %d)\n", yylineno);
        emitPrintf($3, NULL);
        free($3);
        $$ = nullptr;
    }
    | PRINTF LPAREN STRING COMMA arg_list RPAREN SEMI {
        printf("Expanding rule: stmt → PRINTF LPAREN STRING COMMA arg_list RPAREN SEMI (line %d)\n", yylineno);
        emitPrintf($3, $5);
        free($3);
        $$ = nullptr;
    }
    | SCANF LPAREN IDENTIFIER RPAREN SEMI {
        printf("Expanding rule: stmt → SCANF LPAREN IDENTIFIER RPAREN SEMI (line %d)\n", yylineno);
        Symbol* sym = lookup($3);
        if (!sym) {
            reportError("Semantic Error: Variable '%s' not declared (line %d)\n", $3, yylineno);
        } else {
            generateScanfIR($3, sym->type);
        }
        $$ = nullptr;
    }
    /* Loops: like if, the mid-rule actions { ... } run WHILE the loop is being
       read, so the blocks exist before the condition and body are generated.
       In for, the update (i++) is read before the body but must run after it,
       so it is generated into its own for.step block. */
    | FOR LPAREN {
        // Variables declared in the init part (int i = 0) belong to the loop only
        currentScope++;
    } init_expr SEMI {
        $<loop>$ = generateLoopStartIR();
    } expr SEMI {
        if (!$7) {
            reportError("Semantic Error: Invalid condition in for loop (line %d)\n", yylineno);
        }
        generateLoopCondIR($<loop>6, generateConditionIR($7), true);
    } update_expr RPAREN {
        generateForStepEndIR($<loop>6);
    } compound_stmt {
        printf("Expanding rule: stmt → FOR LPAREN init_expr SEMI expr SEMI update_expr RPAREN compound_stmt (line %d)\n", yylineno);
        generateLoopEndIR($<loop>6);
        exitScope(currentScope);
        currentScope--;
        $$ = nullptr;
    }
    | WHILE LPAREN {
        $<loop>$ = generateLoopStartIR();
    } expr RPAREN {
        if (!$4) {
            reportError("Semantic Error: Invalid condition in while loop (line %d)\n", yylineno);
        }
        generateLoopCondIR($<loop>3, generateConditionIR($4), false);
    } compound_stmt {
        printf("Expanding rule: stmt → WHILE LPAREN expr RPAREN compound_stmt (line %d)\n", yylineno);
        generateLoopEndIR($<loop>3);
        $$ = nullptr;
    }
    | if_stmt {
        printf("Expanding rule: stmt → if_stmt (line %d)\n", yylineno);
        $$ = nullptr;
    }
    | RETURN expr SEMI {
        printf("Expanding rule: stmt → RETURN expr SEMI (line %d)\n", yylineno);
        if (!$2) {
            reportError("Semantic Error: Invalid return expression (line %d)\n", yylineno);
            YYERROR;
        }
        printf("Generating return for expr at %p\n", $2);
        generateReturnIR($2);
        $$ = nullptr;
    }
    | switch_head LBRACE case_list RBRACE {
        printf("Expanding rule: stmt → switch_head LBRACE case_list RBRACE (line %d)\n", yylineno);
        generateSwitchEndIR();
        $$ = nullptr;
    }
    | BREAK SEMI {
        printf("Expanding rule: stmt → BREAK SEMI (line %d)\n", yylineno);
        if (!generateBreakIR()) {
            reportError("Semantic Error: 'break' is only allowed inside a loop or switch (line %d)\n", yylineno);
        }
        $$ = nullptr;
    }
    | CONTINUE SEMI {
        printf("Expanding rule: stmt → CONTINUE SEMI (line %d)\n", yylineno);
        if (!generateContinueIR()) {
            reportError("Semantic Error: 'continue' is only allowed inside a loop (line %d)\n", yylineno);
        }
        $$ = nullptr;
    }
    | declaration SEMI { printf("Expanding rule: stmt → declaration SEMI (line %d)\n", yylineno); $$ = nullptr; }
    ;

/* if / else
   Bison runs an action only after its whole rule has been matched. If the
   blocks for an if were created in the action of "IF ( expr ) body", the
   body's code would already have been generated, in the wrong place.
   So if_head reduces as soon as "if (cond)" is read, BEFORE the body,
   and sets up the blocks; the body is then generated inside "then". */
if_head:
    IF LPAREN expr RPAREN {
        printf("Expanding rule: if_head → IF LPAREN expr RPAREN (line %d)\n", yylineno);
        if (!$3) {
            reportError("Semantic Error: Invalid condition in if statement (line %d)\n", yylineno);
            $$ = nullptr;
        } else {
            $$ = generateIfStartIR(generateConditionIR($3));
        }
    }
    ;

if_stmt:
    if_head compound_stmt %prec THEN {
        printf("Expanding rule: if_stmt → if_head compound_stmt (line %d)\n", yylineno);
        generateIfEndIR($1);
    }
    | if_head compound_stmt ELSE {
        // Mid-rule action: runs as soon as "else" is read, before the else-body
        generateIfElseIR($1);
    } else_body {
        printf("Expanding rule: if_stmt → if_head compound_stmt ELSE else_body (line %d)\n", yylineno);
        generateIfEndIR($1);
    }
    ;

else_body:
    compound_stmt { printf("Expanding rule: else_body → compound_stmt (line %d)\n", yylineno); }
    | if_stmt { printf("Expanding rule: else_body → if_stmt (line %d)\n", yylineno); } /* else if */
    ;

/* switch: like if_head, switch_head reduces right after "switch (value)",
   before any case, and emits the switch instruction. */
switch_head:
    SWITCH LPAREN expr RPAREN {
        printf("Expanding rule: switch_head → SWITCH LPAREN expr RPAREN (line %d)\n", yylineno);
        llvm::Value* value = $3;
        if (!value) {
            reportError("Semantic Error: Invalid switch expression (line %d)\n", yylineno);
        } else if (!value->getType()->isIntegerTy(32)) {
            reportError("Semantic Error: Switch expression must be an int (line %d)\n", yylineno);
            value = nullptr;
        }
        if (!value) {
            // Keep going with a dummy value so the cases still parse and
            // more errors can be reported; no output is written anyway.
            value = llvm::ConstantInt::get(context, llvm::APInt(32, 0));
        }
        generateSwitchStartIR(value);
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
            reportError("Semantic Error: Variable '%s' not declared (line %d)\n", $1, yylineno);
            $$ = nullptr;
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
            reportError("Semantic Error: Variable '%s' not declared (line %d)\n", $1, yylineno);
            $$ = nullptr;
        } else {
            llvm::Value* val = builder.CreateLoad(getLLVMType(sym->type), sym->value, $1);
            llvm::Value* inc = builder.CreateAdd(val, llvm::ConstantInt::get(context, llvm::APInt(32, 1)), "inctmp");
            builder.CreateStore(inc, sym->value);
            $$ = inc;
        }
    }
    | IDENTIFIER DECR {
        printf("Expanding rule: update_expr → IDENTIFIER DECR (line %d)\n", yylineno);
        Symbol* sym = lookup($1);
        if (!sym) {
            reportError("Semantic Error: Variable '%s' not declared (line %d)\n", $1, yylineno);
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
            reportError("Semantic Error: Variable '%s' not declared (line %d)\n", $1, yylineno);
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
            reportError("Error: Failed to generate variable declaration for '%s' (line %d)\n", $1, yylineno);
            YYERROR;
        }
        Symbol* sym = lookup($1);
        if (sym && sym->scope == currentScope && sym->kind == VAR) {
            reportError("Semantic Error: Variable '%s' redeclared in scope %d (line %d)\n", $1, currentScope, yylineno);
            YYERROR;
        }
        insertVariable($1, currentType, currentScope, alloc, 0);
    }
    | IDENTIFIER ASSIGN expr {
        printf("Expanding rule: var_decl → IDENTIFIER ASSIGN expr (line %d)\n", yylineno);
        llvm::Value* alloc = generateVariableDeclIR($1, currentType, currentScope);
        if (!alloc) {
            reportError("Error: Failed to generate variable declaration for '%s' (line %d)\n", $1, yylineno);
            YYERROR;
        }
        Symbol* sym = lookup($1);
        if (sym && sym->scope == currentScope && sym->kind == VAR) {
            reportError("Semantic Error: Variable '%s' redeclared in scope %d (line %d)\n", $1, currentScope, yylineno);
            YYERROR;
        }
        insertVariable($1, currentType, currentScope, alloc, 0);
        if (!$3) {
            reportError("Error: Expression for assignment to '%s' is invalid (line %d)\n", $1, yylineno);
            YYERROR;
        }
        if ($3->getType()->isIntegerTy(32) ? TYPE_INT : ($3->getType()->isFloatTy() ? TYPE_FLOAT : TYPE_BOOL) != currentType) {
            reportError("Type Error: Cannot assign incompatible type to '%s' (line %d)\n", $1, yylineno);
        }
        if (currentScope == 0) {
            // Global: no code runs at global scope, so instead of a store
            // the value becomes the global's initial value.
            if (!setGlobalInitializerIR(alloc, $3)) {
                reportError("Semantic Error: Global variable '%s' must be initialized with a constant of the same type (line %d)\n", $1, yylineno);
            }
        } else {
            generateAssignIR($1, $3);
        }
    }
    | IDENTIFIER LBRACKET NUMBER RBRACKET {
        printf("Expanding rule: var_decl → IDENTIFIER LBRACKET NUMBER RBRACKET (line %d)\n", yylineno);
        if ($3 <= 0) {
            reportError("Semantic Error: Array '%s' must have a size greater than 0 (line %d)\n", $1, yylineno);
            YYERROR;
        }
        Symbol* sym = lookup($1);
        if (sym && sym->scope == currentScope && sym->kind == VAR) {
            reportError("Semantic Error: Variable '%s' redeclared in scope %d (line %d)\n", $1, currentScope, yylineno);
            YYERROR;
        }
        llvm::Value* alloc = generateArrayDeclIR($1, currentType, $3, currentScope);
        if (!alloc) {
            reportError("Error: Failed to generate array declaration for '%s' (line %d)\n", $1, yylineno);
            YYERROR;
        }
        insertVariable($1, currentType, currentScope, alloc, $3);
    }
    ;

case_list:
    case_list case_item { printf("Expanding rule: case_list → case_list case_item (line %d)\n", yylineno); }
    | case_item { printf("Expanding rule: case_list → case_item (line %d)\n", yylineno); }
    ;

/* A case's statements may be empty, so several labels can share one body:
   case 1: case 2: x = 5; break; */
case_item:
    case_label stmt_list_opt { printf("Expanding rule: case_item → case_label stmt_list_opt (line %d)\n", yylineno); }
    ;

/* case_label reduces as soon as "case 2:" is read, BEFORE that case's
   statements, so they are generated inside the new case block. */
case_label:
    CASE NUMBER COLON {
        printf("Expanding rule: case_label → CASE NUMBER COLON (line %d)\n", yylineno);
        if (generateCaseIR($2) != 0) {
            reportError("Semantic Error: Duplicate case value %d in switch (line %d)\n", $2, yylineno);
        }
    }
    | CASE MINUS NUMBER COLON {
        printf("Expanding rule: case_label → CASE MINUS NUMBER COLON (line %d)\n", yylineno);
        if (generateCaseIR(-$3) != 0) {
            reportError("Semantic Error: Duplicate case value %d in switch (line %d)\n", -$3, yylineno);
        }
    }
    | DEFAULT COLON {
        printf("Expanding rule: case_label → DEFAULT COLON (line %d)\n", yylineno);
        if (generateDefaultCaseIR() != 0) {
            reportError("Semantic Error: Multiple default labels in switch (line %d)\n", yylineno);
        }
    }
    ;

expr:
    expr PLUS expr {
        printf("Expanding rule: expr → expr PLUS expr (line %d)\n", yylineno);
        if ($1 && $3 && $1->getType() != $3->getType()) {
            reportError("Type Error: Mismatched types in addition at line %d\n", yylineno);
        }
        $$ = generateExprIR($1 && $1->getType()->isIntegerTy(32) ? TYPE_INT : TYPE_FLOAT, "+", $1, $3, "", 0, 0.0, false);
    }
    | expr MINUS expr {
        printf("Expanding rule: expr → expr MINUS expr (line %d)\n", yylineno);
        if ($1 && $3 && $1->getType() != $3->getType()) {
            reportError("Type Error: Mismatched types in subtraction at line %d\n", yylineno);
        }
        $$ = generateExprIR($1 && $1->getType()->isIntegerTy(32) ? TYPE_INT : TYPE_FLOAT, "-", $1, $3, "", 0, 0.0, false);
    }
    | expr MULT expr {
        printf("Expanding rule: expr → expr MULT expr (line %d)\n", yylineno);
        if ($1 && $3 && $1->getType() != $3->getType()) {
            reportError("Type Error: Mismatched types in multiplication at line %d\n", yylineno);
        }
        $$ = generateExprIR($1 && $1->getType()->isIntegerTy(32) ? TYPE_INT : TYPE_FLOAT, "*", $1, $3, "", 0, 0.0, false);
    }
    | expr DIV expr {
        printf("Expanding rule: expr → expr DIV expr (line %d)\n", yylineno);
        if ($1 && $3 && $1->getType() != $3->getType()) {
            reportError("Type Error: Mismatched types in division at line %d\n", yylineno);
        }
        $$ = generateExprIR($1 && $1->getType()->isIntegerTy(32) ? TYPE_INT : TYPE_FLOAT, "/", $1, $3, "", 0, 0.0, false);
    }
    | expr MOD expr {
        printf("Expanding rule: expr → expr MOD expr (line %d)\n", yylineno);
        if ($1 && $3 && $1->getType() != $3->getType()) {
            reportError("Type Error: Mismatched types in modulo at line %d\n", yylineno);
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
            reportError("Semantic Error: Variable '%s' not declared (line %d)\n", $1, yylineno);
            $$ = nullptr;
        } else if (sym->arraySize > 0) {
            reportError("Semantic Error: Array '%s' must be used with an index, e.g. %s[0] (line %d)\n", $1, $1, yylineno);
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
            reportError("Semantic Error: Invalid arguments for function '%s' (line %d)\n", $1, yylineno);
            $$ = nullptr;
        } else {
            $$ = generateFunctionCallIR($1, $3);
        }
    }
    | IDENTIFIER LBRACKET expr RBRACKET {
        printf("Expanding rule: expr → IDENTIFIER LBRACKET expr RBRACKET (line %d)\n", yylineno);
        Symbol* sym = checkArrayAccess($1, $3);
        $$ = sym ? generateArrayLoadIR(sym->value, sym->type, sym->arraySize, $3) : nullptr;
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
    errorCount++;
}

// Every semantic and type error is printed through this one function, so
// it can also be counted. A compiler must not report success (or produce
// output) when the program had errors, even if parsing itself finished.
void reportError(const char* format, ...) {
    va_list args;
    va_start(args, format);
    vprintf(format, args);
    va_end(args);
    errorCount++;
}

// The lexer gives us the string literal exactly as written, quotes and
// backslashes included. Strip the quotes and turn escape sequences like \n
// into the real characters they stand for.
static std::string unescapeString(const char* quoted) {
    std::string out;
    size_t len = strlen(quoted);
    for (size_t i = 1; i + 1 < len; i++) { // skip the opening and closing quote
        if (quoted[i] == '\\' && i + 2 < len) {
            i++;
            switch (quoted[i]) {
                case 'n': out += '\n'; break;
                case 't': out += '\t'; break;
                case '\\': out += '\\'; break;
                case '"': out += '"'; break;
                default: out += '\\'; out += quoted[i]; break;
            }
        } else {
            out += quoted[i];
        }
    }
    return out;
}

// printf supports two styles:
//   1. A real C format string, recognized by containing '%':
//        printf("x=%d y=%f\n", x, y);   → passed to C's printf unchanged
//   2. Label style, for strings without '%' (and for no string at all):
//        printf("Sum: ", sum);  → prints "Sum: 15" and a newline
//        printf(a, b);          → prints "1 2" and a newline
//        printf("Done\n");      → prints "Done" and one newline (not two)
//      Here we build the format ourselves from each argument's type.
void emitPrintf(const char* quoted, Param* args) {
    std::string text = quoted ? unescapeString(quoted) : "";
    std::vector<llvm::Value*> values;
    for (Param* p = args; p != NULL; p = p->next) {
        if (!p->value) {
            reportError("Semantic Error: Invalid argument to printf (line %d)\n", yylineno);
            return;
        }
        values.push_back(p->value);
    }

    std::string format = text;
    if (text.find('%') == std::string::npos) {
        for (size_t i = 0; i < values.size(); i++) {
            if (i > 0) format += " ";
            format += values[i]->getType()->isFloatTy() ? "%f" : "%d";
        }
        // Add the newline only if the text doesn't already end with one
        if (format.empty() || format[format.size() - 1] != '\n') {
            format += "\n";
        }
    }
    generatePrintfIR(format, values);

    // The argument list was malloc'd by arg_list and isn't needed anymore
    while (args != NULL) {
        Param* next = args->next;
        free(args);
        args = next;
    }
}

// Semantic checks shared by array reads (a[i]) and writes (a[i] = x):
// the name must be a declared array, the index must be an int, and if the
// index is a constant we can already check it is inside the array.
// Returns the array's symbol, or NULL after printing an error.
Symbol* checkArrayAccess(const char* name, llvm::Value* index) {
    Symbol* sym = lookup(name);
    if (!sym) {
        reportError("Semantic Error: Variable '%s' not declared (line %d)\n", name, yylineno);
        return NULL;
    }
    if (sym->arraySize == 0) {
        reportError("Semantic Error: '%s' is not an array (line %d)\n", name, yylineno);
        return NULL;
    }
    if (!index || !index->getType()->isIntegerTy(32)) {
        reportError("Semantic Error: Index of array '%s' must be an int (line %d)\n", name, yylineno);
        return NULL;
    }
    if (llvm::isa<llvm::ConstantInt>(index)) {
        long long i = ((llvm::ConstantInt*)index)->getSExtValue();
        int size = sym->arraySize;
        if (i < 0 || i >= size) {
            reportError("Semantic Error: Index %lld is out of bounds for array '%s' of size %d (line %d)\n", i, name, size, yylineno);
            return NULL;
        }
    }
    return sym;
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

    // Only produce output.ll for an error-free program. On failure, delete
    // any output.ll left from an earlier run so it can't be mistaken for
    // this one, and exit with 1 so scripts (and make) see the failure.
    bool ok = (result == 0 && errorCount == 0);
    if (ok && !writeIRToFile("output.ll")) {
        errorCount++; // the IR failed LLVM's verifier
        ok = false;
    }
    if (!ok) {
        remove("output.ll");
        fprintf(stderr, "Compilation failed with %d error(s).\n", errorCount > 0 ? errorCount : 1);
        return 1;
    }
    return 0;

    // HOW TO RUN ??
    //  make clean
    //  make
    //  ./compiler testCaseExamples/test.c
    //  llvm-as output.ll -o output.bc
    //  lli output.bc
    //  echo $?
}
