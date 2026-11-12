/* D-02 C oracle — built with aarch64-linux-gnu-gcc -O2 -fwrapv -static,
 * run under qemu-aarch64 -L /usr/aarch64-linux-gnu.  Both programs must agree.
 * The double-local shape returns 0; the nine-double-parameter shape returns 8.
 */
int slot1(void){ int lead=1; double x=2.5; int p1,p2,p3,p4,p5,p6,p7;
    p1=p2=p3=p4=p5=p6=p7=0; p7=99;
    (void)lead;(void)p1;(void)p2;(void)p3;(void)p4;(void)p5;(void)p6;(void)p7;
    return x==2.5 ? 0 : 1; }
static double nine(double a,double b,double c,double d,double e,
                   double g,double h,double i,double j){
    volatile long pad[480] = {0}; (void)pad; return j-a; }
int main(void){ return (int)nine(1,2,3,4,5,6,7,8,9) == 8 ? slot1() : 9; }
