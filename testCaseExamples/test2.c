#include <stdio.h>

// Function prototypes
int add(int, int );
int factorial(int );
void printMessage();
bool isEven(int);

int main() {
    // Variable declarations
    int a = 10, b = 20, result;
    float x = 5.5, y = 2.2;
    bool flag = true;

    // Arithmetic operations
    result = a + b * 2 - (a % b);
    float division = x / y;

    // Logical operations
    if (flag && (a > b || x < y)) {
        printf("Condition met!\n");
    } else {
        printf("Condition not met!\n");
    }

    // While loop
    int i = 0;
    while (i < 5) {
        printf("While Loop: %d\n", i);
        i++;
    }

    // For loop
    for (int j = 0; j < 5; j++) {
        printf("For Loop: %d\n", j);
    }

    // Switch-case statement
    int num = 10;
    switch (num) {
        case 5:
            printf("Number is 5\n");
            break;
        case 10:
            printf("Number is 10\n");
            break;
        default:
            printf("Number is unknown\n");
            break;
    }

    // Function calls
    result = add(a, b);
    printf("Addition result: %d\n", result);

    result = factorial(5);
    printf("Factorial of 5: %d\n", result);

    printMessage();

    if (isEven(4)) {
        printf("4 is even\n");
    } else {
        printf("4 is odd\n");
    }

    return 0;
}

// Function definitions
int add(int a, int b) {
    return a + b;
}

int factorial(int n) {
    if (n == 0) {
        return 1;
    }
    return n * factorial(n - 1); // Recursion
}

void printMessage() {
    printf("Hello from a function!\n");
}

bool isEven(int num) {
    return (num % 2 == 0);
}
