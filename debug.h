#ifndef DEBUG_H
#define DEBUG_H

// Debug output (every token, every grammar rule, every IR step) is only
// printed when the compiler is run with -v:  ./compiler -v program.c
// Errors are always printed.
extern int verbose;
void debugPrint(const char* format, ...);

#endif
