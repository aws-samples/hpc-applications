#define _GNU_SOURCE
#include <mpi.h>
#include <stdio.h>
#include <stdlib.h>
#include <sched.h>

typedef struct {
    int cpu;
    int rank;
} entry_t;

int compare(const void *a, const void *b) {
    const entry_t *ea = (const entry_t *)a;
    const entry_t *eb = (const entry_t *)b;
    return ea->cpu - eb->cpu;
}

int main(int argc, char *argv[]) {
    MPI_Init(&argc, &argv);

    int world_size, world_rank;
    MPI_Comm_size(MPI_COMM_WORLD, &world_size);
    MPI_Comm_rank(MPI_COMM_WORLD, &world_rank);

    int cpu = sched_getcpu();
    entry_t local = { cpu, world_rank };

    entry_t *all = NULL;
    if (world_rank == 0) {
        all = malloc(world_size * sizeof(entry_t));
    }

    /* Create MPI datatype for entry_t */
    MPI_Datatype entry_type;
    MPI_Type_contiguous(2, MPI_INT, &entry_type);
    MPI_Type_commit(&entry_type);

    MPI_Gather(&local, 1, entry_type,
               all,   1, entry_type,
               0, MPI_COMM_WORLD);

    if (world_rank == 0) {
        qsort(all, world_size, sizeof(entry_t), compare);

        for (int i = 0; i < world_size; i++) {
            printf("Rank %d running on CPU core %d\n",
                   all[i].rank, all[i].cpu);
        }
        free(all);
    }

    MPI_Type_free(&entry_type);
    MPI_Finalize();
    return 0;
}
