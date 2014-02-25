// ----------------------------------------------------------------
// Gunrock -- Fast and Efficient GPU Graph Library
// ----------------------------------------------------------------
// This source code is distributed under the terms of LICENSE.TXT
// in the root directory of this source distribution.
// ----------------------------------------------------------------

/**
 * @file
 * rp_partitioner.cuh
 *
 * @brief Implementation of random partitioner
 */

#pragma once

#include <stdlib.h>
#include <time.h>
#include <gunrock/app/partitioner_base.cuh>
#include <gunrock/util/memset_kernel.cuh>

namespace gunrock {
namespace app {
namespace rp {

template <
    typename VertexId,
    typename SizeT,
    typename Value>
struct RandomPartitioner : PartitionerBase<VertexId,SizeT,Value>
{
    typedef Csr<VertexId,Value,SizeT> GraphT;

    // Members
    float *weitage;

    // Methods
    RandomPartitioner()
    {
        weitage=NULL;
    }

    RandomPartitioner(const GraphT &graph,
                      int   num_gpus,
                      float *weitage = NULL)
    {
        Init(graph,num_gpus);
        this->weitage=new float[num_gpus+1];
        if (weitage==NULL)
            for (int gpu=0;gpu<num_gpus;gpu++) this->weitage[gpu]=1.0f/num_gpus;
        else {
            float sum=0;
            for (int gpu=0;gpu<num_gpus;gpu++) sum+=weitage[gpu];
            for (int gpu=0;gpu<num_gpus;gpu++) this->weitage[gpu]=weitage[gpu]/sum; 
        }
        for (int gpu=0;gpu<num_gpus;gpu++) this->weitage[gpu+1]+=weitage[gpu];
    }

    ~RandomPartitioner()
    {
        if (weitage!=NULL)
        {
            delete[] weitage;weitage=NULL;
        }
    }

    template <bool LOAD_EDGE_VALUES, bool LOAD_NODE_VALUES>
    cudaError_t Partition(
        GraphT*    &sub_graphs,
        int**      &partition_tables,
        VertexId** &convertion_tables,
        SizeT**    &in_offsets,
        SizeT**    &out_offsets)
    {
        cudaError_t retval = cudaSuccess;
        int*        tpartition_table=this->partition_tables[0];
        srand(time(NULL));
        for (SizeT node=0;node<this->graph->nodes;node++)
        {
            float x=rand()*1.0f/RAND_MAX;
            tpartition_table[node]=this->num_gpus;
            for (int gpu=0;gpu<this->num_gpus;gpu++)
            if (x<=weitage[gpu])
            {
                tpartition_table[node]=gpu;
                break;
            }
            if (tpartition_table[node]==this->num_gpus) tpartition_table[node]=(rand() % this->num_gpus);
        }
        retval = this->MakeSubGrasph
                 <LOAD_EDGE_VALUES, LOAD_NODE_VALUES>
                 (true );
        sub_graphs        = this->sub_graphs;
        partition_tables  = this->partition_tables;
        convertion_tables = this->convertion_tables;
        in_offsets        = this->in_offsets;
        out_offsets       = this->out_offsets;
        return retval;
    }
};

} //namespace rp
} //namespace app
} //namespace gunrock

// Leave this at the end of the file
// Local Variables:
// mode:c++
// c-file-style: "NVIDIA"
// End: