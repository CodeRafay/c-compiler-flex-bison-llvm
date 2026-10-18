int x, y;
float f;
bool flag;

int add( int a, int b) {
    int result;
    result = a + b;
    float returnKrnaBhaiKo;
    return returnKrnaBhaiKo;
}

void main() {
    int z;
    x = 5;
    y = 10;
    z = add(x, y);
    f = 3.14;
    x = f;           // ❌ Should trigger type mismatch: float → int
    flag = x > y;

    undeclaredVar = 100; // ❌ Should trigger undeclared variable error
}
