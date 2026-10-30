// C twin of examples/enum_demo.ast. The Aster source and this file must agree
// byte for byte at run time: each enumerator is the same i32 constant, and the
// arithmetic is identical. The enumeration name `Byte` is nominal in Aster and
// C alike — only the value 255 flows out, which is what the differential layer
// (enum-checks.sh [4/9]) compares.
enum Byte { A=1, B=2, C=4, D=8, E=16, F=32, G=64, H=128 };

int main(void) {
    enum Byte h = H;
    int rest = A + B + C + D + E + F + G;   // 127
    int t = rest + h;                        // 255
    return t;
}
