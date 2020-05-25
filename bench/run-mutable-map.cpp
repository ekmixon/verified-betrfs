#include "bench/MutableMap.h"

int main(int argc, char**argv) {
    if (argc != 4) {
        printf("invalid number of arguments\n");
        return -1;
    }
    uint64 seed = atol(argv[1]);
    uint64 ops = atol(argv[2]);
    bool dry = (strcmp(argv[3], "true") == 0);
    printf("METADATA title running %llu ops with seed %llu dry run %d\n", ops, seed, dry);
    MutableMapBench_Compile::__default::Run(seed, ops, dry);
    return 0;
}
