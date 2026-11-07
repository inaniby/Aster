/* C oracle for F-07: int64_t can represent every uint32_t, so b is
   promoted to int64_t and the comparison is signed -> returns 1. */
#include <stdint.h>
int main(void){ int64_t a=-5; uint32_t b=3; return (a<b)?1:0; }
