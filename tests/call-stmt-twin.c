// C twin of examples/call-stmt.ast (v0.23.39-dev): the three fire-and-forget
// field calls plus two value calls must match the Aster program's exit code.
#include <stdio.h>

struct Handlers { int (*onClick)(int); int (*onMove)(int,int); };
static int fired = 0;
static int onClickImpl(int x){ fired = fired + 1; return x + 1; }
static int onMoveImpl(int x, int y){ fired = fired + 1; return x + y; }

int main(void){
    struct Handlers h = { onClickImpl, onMoveImpl };
    // fire-and-forget: return value dropped, only the increment matters.
    h.onClick(41);
    h.onClick(1);
    h.onMove(10, 20);
    // the same handlers, called for their value:
    int s = h.onClick(100) + h.onMove(2, 3);
    // fired = 5 (three fire-and-forget + two value calls); s = 106.
    return fired * 10 + (s % 10);
}
