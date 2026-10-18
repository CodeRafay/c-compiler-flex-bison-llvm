int main() {
    int x = 5;
    bool flag = x > 3 && x < 10;
    float y = 2.5;
    int sum = 0;
    
    // For loop
    for (int i = 0; i < x; i++) {
        sum = sum + i;
    }
    
    // While loop
    while (x > 0) {
        x--;
    }
    
    // Switch-case
    switch (sum) {
        case 10:
            sum = sum + 1;
            break;
        default:
            sum = sum + 2;
    }
    
    // I/O
    printf(sum);
    scanf(x);
    
    return sum; // Changed from returning fact
}