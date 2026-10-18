#include <stdio.h>

int sumOfDigits(int num) {
    int sum = 0;
    while (num > 0) {
        sum = sum + (num % 10);
        num = num / 10;
    }
    return sum;
}

int main() {
    int num = 12345;
    int result = sumOfDigits(num);
    printf(result);

    return 0;
}
