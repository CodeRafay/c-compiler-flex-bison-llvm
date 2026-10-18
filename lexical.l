%{
#include <stdlib.h>
#include <stdio.h>
#include <string.h>
#include "symbol_table.h"

// Define tokens manually for standalone mode
#ifdef STANDALONE_LEXER
typedef union {
    int num;
    float fnum;
    char *str;
    char *id;
} YYSTYPE;

YYSTYPE yylval;  // Declare yylval for standalone mode

#define INT 1
#define FLOAT 2
#define BOOL 3
#define RETURN 4
#define VOID 5
#define MAIN 6
#define PRINTF 7
#define SCANF 8
#define FOR 9
#define IF 10
#define ELSE 11
#define WHILE 12
#define SWITCH 13
#define CASE 14
#define LE 15
#define LT 16
#define GT 17
#define GE 18
#define EQ 19
#define NEQ 20
#define OR 21
#define AND 22
#define NOT 23
#define INCR 24
#define COMMA 25
#define ASSIGN 26
#define LPAREN 27
#define RPAREN 28
#define LBRACE 29
#define RBRACE 30
#define SEMI 31
#define PLUS 32
#define MINUS 33
#define MULT 34
#define DIV 35
#define MOD 36
#define NUMBER 37
#define IDENTIFIER 38
#define TRUE 39
#define FALSE 40
#define BREAK 41
#define DEFAULT 42
#define COLON 43
#define STRING 44
#define DECR 45
#define FLOATNUMBER 46
#else
#include "parser.tab.h"
#endif

int return_token(int token) {
#ifndef STANDALONE_LEXER
    return token;
#else
    return token;
#endif
}


%}

%option yylineno

/* Regular expression definitions */
DIGIT   -?[0-9]+
FLOATNUM -?[0-9]*\.[0-9]+
ID      [a-zA-Z_][a-zA-Z0-9_]*
WS      [ \t]+
NEWLINE \n
%%

"#".*               { printf("Processing token at line %d: Preprocessor directive: %s\n", yylineno, yytext); }
"int"               { printf("Processing token at line %d: INT, Lexeme: %s\n", yylineno, yytext); return return_token(INT); }
"float"             { printf("Processing token at line %d: FLOAT, Lexeme: %s\n", yylineno, yytext); return return_token(FLOAT); }
"bool"              { printf("Processing token at line %d: BOOL, Lexeme: %s\n", yylineno, yytext); return return_token(BOOL); }
"void"              { printf("Processing token at line %d: VOID, Lexeme: %s\n", yylineno, yytext); return return_token(VOID); }
"return"            { printf("Processing token at line %d: RETURN, Lexeme: %s\n", yylineno, yytext); return return_token(RETURN); }
"main"              { printf("Processing token at line %d: MAIN, Lexeme: %s\n", yylineno, yytext); return return_token(MAIN); }
"printf"            { printf("Processing token at line %d: PRINTF, Lexeme: %s\n", yylineno, yytext); return return_token(PRINTF); }
"scanf"             { printf("Processing token at line %d: SCANF, Lexeme: %s\n", yylineno, yytext); return return_token(SCANF); }
"for"               { printf("Processing token at line %d: FOR, Lexeme: %s\n", yylineno, yytext); return return_token(FOR); }
"if"                { printf("Processing token at line %d: IF, Lexeme: %s\n", yylineno, yytext); return return_token(IF); }
"else"              { printf("Processing token at line %d: ELSE, Lexeme: %s\n", yylineno, yytext); return return_token(ELSE); }
"while"             { printf("Processing token at line %d: WHILE, Lexeme: %s\n", yylineno, yytext); return return_token(WHILE); }
"switch"            { printf("Processing token at line %d: SWITCH, Lexeme: %s\n", yylineno, yytext); return return_token(SWITCH); }
"case"              { printf("Processing token at line %d: CASE, Lexeme: %s\n", yylineno, yytext); return return_token(CASE); }
"true"              { printf("Processing token at line %d: TRUE, Lexeme: %s\n", yylineno, yytext); return return_token(TRUE); }
"false"             { printf("Processing token at line %d: FALSE, Lexeme: %s\n", yylineno, yytext); return return_token(FALSE); }
"break"             { printf("Processing token at line %d: BREAK, Lexeme: %s\n", yylineno, yytext); return return_token(BREAK); }
"default"           { printf("Processing token at line %d: DEFAULT, Lexeme: %s\n", yylineno, yytext); return return_token(DEFAULT); }
"<="                { printf("Processing token at line %d: LE, Lexeme: %s\n", yylineno, yytext); return return_token(LE); }
"<"                 { printf("Processing token at line %d: LT, Lexeme: %s\n", yylineno, yytext); return return_token(LT); }
">"                 { printf("Processing token at line %d: GT, Lexeme: %s\n", yylineno, yytext); return return_token(GT); }
">="                { printf("Processing token at line %d: GE, Lexeme: %s\n", yylineno, yytext); return return_token(GE); }
"=="                { printf("Processing token at line %d: EQ, Lexeme: %s\n", yylineno, yytext); return return_token(EQ); }
"!="                { printf("Processing token at line %d: NEQ, Lexeme: %s\n", yylineno, yytext); return return_token(NEQ); }
"&&"                { printf("Processing token at line %d: AND, Lexeme: %s\n", yylineno, yytext); return return_token(AND); }
"||"                { printf("Processing token at line %d: OR, Lexeme: %s\n", yylineno, yytext); return return_token(OR); }
"!"                 { printf("Processing token at line %d: NOT, Lexeme: %s\n", yylineno, yytext); return return_token(NOT); }
"++"                { printf("Processing token at line %d: INCR, Lexeme: %s\n", yylineno, yytext); return return_token(INCR); }
"--"                { printf("Processing token at line %d: INCR, Lexeme: %s\n", yylineno, yytext); return return_token(DECR); }
","                 { printf("Processing token at line %d: COMMA, Lexeme: %s\n", yylineno, yytext); return return_token(COMMA); }
"="                 { printf("Processing token at line %d: ASSIGN, Lexeme: %s\n", yylineno, yytext); return return_token(ASSIGN); }
"("                 { printf("Processing token at line %d: LPAREN, Lexeme: %s\n", yylineno, yytext); return return_token(LPAREN); }
")"                 { printf("Processing token at line %d: RPAREN, Lexeme: %s\n", yylineno, yytext); return return_token(RPAREN); }
"{"                 { printf("Processing token at line %d: LBRACE, Lexeme: %s\n", yylineno, yytext); return return_token(LBRACE); }
"}"                 { printf("Processing token at line %d: RBRACE, Lexeme: %s\n", yylineno, yytext); return return_token(RBRACE); }
":"                 { printf("Processing token at line %d: COLON, Lexeme: %s\n", yylineno, yytext); return return_token(COLON); }
";"                 { printf("Processing token at line %d: SEMI, Lexeme: %s\n", yylineno, yytext); return return_token(SEMI); }
"+"                 { printf("Processing token at line %d: PLUS, Lexeme: %s\n", yylineno, yytext); return return_token(PLUS); }
"-"                 { printf("Processing token at line %d: MINUS, Lexeme: %s\n", yylineno, yytext); return return_token(MINUS); }
"*"                 { printf("Processing token at line %d: MULT, Lexeme: %s\n", yylineno, yytext); return return_token(MULT); }
"/"                 { printf("Processing token at line %d: DIV, Lexeme: %s\n", yylineno, yytext); return return_token(DIV); }
"%"                 { printf("Processing token at line %d: MOD, Lexeme: %s\n", yylineno, yytext); return return_token(MOD); }
\"([^\"]*)\" {
    printf("Processing token at line %d: STRING, Lexeme: %s\n", yylineno, yytext);
    yylval.str = strdup(yytext); // You can also remove the quotes manually if needed
    return return_token(STRING);
}

{FLOATNUM} {
    printf("Processing token at line %d: FLOAT NUMBER, Lexeme: %s\n", yylineno, yytext);
    yylval.fnum = atof(yytext);
    return return_token(FLOATNUMBER); 
}

{DIGIT} {
    printf("Processing token at line %d: NUMBER, Lexeme: %s\n", yylineno, yytext);
    yylval.num = atoi(yytext);
    return return_token(NUMBER);
}

{ID} {
    printf("Processing token at line %d: IDENTIFIER, Lexeme: %s\n", yylineno, yytext);
    yylval.id = strdup(yytext); // strdup allocates a copy of the lexeme
    return return_token(IDENTIFIER);
}
{WS}                { /* ignore whitespace */ }
{NEWLINE}           { /* ignore newlines */ }
"//".*              { /* Ignore single line comments */ }
"/*"([^*]|(\*+[^*/]))*"*/" { /* Ignore multi-line comments */ }
.                   { printf("Processing token at line %d: Unknown character: %s\n", yylineno, yytext); }


%%

int yywrap(void) {
    return 1;
}

// Conditionally include the main function for standalone mode
#ifdef STANDALONE_LEXER
int main(int argc, char *argv[]) {
    if (argc != 2) {
        fprintf(stderr, "Usage: %s <input_file>\n", argv[0]);
        return 1;
    }

    FILE *file = fopen(argv[1], "r");
    if (!file) {
        perror("Error opening file");
        return 1;
    }

    yyin = file;  // Set input file
    
    while (yylex()) {
        // Keep calling yylex() until EOF
    }

    fclose(file);
    return 0;
}
#endif
