// Simple language test program

// Variable declarations and basic data types
int a,b;
float x, y;
bool flag;

// Function declaration
int factorial(int n){

    int a;
}

void main() {
    // Assign values
    a = 10;
    b = 5;
    x = 3.5;
    y = 2.0;
    flag = true;

    // Arithmetic operations
    int sum = a + 5;
    int diff = a - b;
    int product = a * b;
    int quotient = a / b;
    int remainder = a % b;

    // Relational and logical operations
    bool condition1 = (a > b) && (x < y);
    bool condition2 = (a == b) || !flag;

    // Print statements
  printf("Sum: ", sum);
  printf("Difference: ", diff);
  printf("Product: ", product);
  printf("Quotient: ", quotient);
  printf("Remainder: ", remainder);
    
    // If-else statement
    if (a > b) {
      printf("a is greater than b");
    } else {
      printf("b is greater than or equal to a");
    }

    // While loop
    int counter = 0;
    while (counter < 5) {
      printf("Counter: ", counter);
        counter = counter + 1;
    }

    // For loop
    for (int i = 0; i < 5; i = i + 1) {
      printf("For loop iteration: ", i);
    }

    // Switch-case statement
    switch (a) {
        case 5:
          printf("a is 5");
            break;
        case 10:
          printf("a is 10");
            break;
        default:
          printf("a has another value");
            break;
    }

    // Function call
    int fact = factorial(5);
  printf("Factorial of 5 is: ", fact);
}

// Recursive function to calculate factorial
int factorial(int n) {
    if (n <= 1) {
        return 1;
    }
    return n * factorial(n - 1);
}
