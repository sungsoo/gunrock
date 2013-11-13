// ----------------------------------------------------------------
// Gunrock -- Fast and Efficient GPU Graph Library
// ----------------------------------------------------------------
// This source code is distributed under the terms of LICENSE.TXT
// in the root directory of this source distribution.
// ----------------------------------------------------------------

/**
 * @file
 * cta.cuh
 *
 * @brief CTA tile-processing abstraction for Vertex Map
 */

#pragma once

#include <gunrock/util/io/modified_load.cuh>
#include <gunrock/util/io/modified_store.cuh>
#include <gunrock/util/io/initialize_tile.cuh>
#include <gunrock/util/io/load_tile.cuh>
#include <gunrock/util/io/store_tile.cuh>
#include <gunrock/util/io/scatter_tile.cuh>
#include <gunrock/util/cta_work_distribution.cuh>

#include <gunrock/util/operators.cuh>
#include <gunrock/util/reduction/serial_reduce.cuh>
#include <gunrock/util/reduction/tree_reduce.cuh>

#include <gunrock/util/scan/cooperative_scan.cuh>

namespace gunrock {
namespace oprtr {
namespace vertex_map {


/**
 * @brief CTA tile-processing abstraction for the vertex mapping operator.
 *
 * @tparam KernelPolicy Kernel policy type for the vertex mapping.
 * @tparam ProblemData Problem data type for the vertex mapping.
 * @tparam Functor Functor type for the specific problem type.
 *
 */
template <typename KernelPolicy, typename ProblemData, typename Functor>
struct Cta
{
    //---------------------------------------------------------------------
    // Typedefs and Constants
    //---------------------------------------------------------------------

    typedef typename KernelPolicy::VertexId         VertexId;
    typedef typename KernelPolicy::SizeT            SizeT;

    typedef typename KernelPolicy::RakingDetails    RakingDetails;
    typedef typename KernelPolicy::SmemStorage      SmemStorage;

    typedef typename ProblemData::DataSlice         DataSlice;

    /**
     * Members
     */

    // Input and output device pointers
    VertexId                *d_in;                      // Incoming edge frontier
    VertexId                *d_out;                     // Outgoing vertex frontier
    DataSlice               *problem;                   // Problem data

    // Work progress
    VertexId                queue_index;                // Current frontier queue counter index
    util::CtaWorkProgress   &work_progress;             // Atomic workstealing and queueing counters
    SizeT                   max_out_frontier;           // Maximum size (in elements) of outgoing vertex frontier
    int                     num_gpus;                   // Number of GPUs

    // Operational details for raking_scan_grid
    RakingDetails           raking_details;
    
    // Shared memory for the CTA
    SmemStorage             &smem_storage;

    //---------------------------------------------------------------------
    // Helper Structures
    //---------------------------------------------------------------------

    /**
     * @brief Tile of incoming frontier to process
     *
     * @tparam LOG_LOADS_PER_TILE   Size of the loads per tile.
     * @tparam LOG_LOAD_VEC_SIZE    Size of the vector size per load.
     */
    template <
        int LOG_LOADS_PER_TILE,
        int LOG_LOAD_VEC_SIZE>
    struct Tile
    {
        //---------------------------------------------------------------------
        // Typedefs and Constants
        //---------------------------------------------------------------------

        enum {
            LOADS_PER_TILE      = 1 << LOG_LOADS_PER_TILE,
            LOAD_VEC_SIZE       = 1 << LOG_LOAD_VEC_SIZE
        };


        //---------------------------------------------------------------------
        // Members
        //---------------------------------------------------------------------

        // Dequeued vertex ids
        VertexId    vertex_id[LOADS_PER_TILE][LOAD_VEC_SIZE];
        VertexId    predecessor_id[LOADS_PER_TILE][LOAD_VEC_SIZE];

        // Whether or not the corresponding vertex_id is valid for exploring
        unsigned char   flags[LOADS_PER_TILE][LOAD_VEC_SIZE];

        // Global scatter offsets
        SizeT       ranks[LOADS_PER_TILE][LOAD_VEC_SIZE];

        //---------------------------------------------------------------------
        // Helper Structures
        //---------------------------------------------------------------------

        /**
         * @brief Iterate over vertex ids in tile.
         */
        template <int LOAD, int VEC, int dummy = 0>
        struct Iterate
        {
            /**
             * @brief Initialize flag values for compact new frontier. If vertex id equals to -1, then discard it in the new frontier.
             *
             * @param[in] tile Tile object holds the vertex ids, ranks and flags.
             */
            static __device__ __forceinline__ void InitFlags(Tile *tile)
            {
                // Initially valid if vertex-id is valid
                tile->flags[LOAD][VEC] = (tile->vertex_id[LOAD][VEC] == -1) ? 0 : 1;
                tile->ranks[LOAD][VEC] = tile->flags[LOAD][VEC];

                // Next
                Iterate<LOAD, VEC + 1>::InitFlags(tile);
            }

            /**
             * @brief Set vertex id to -1 if we want to cull this vertex from the outgoing frontier.
             *
             */
            static __device__ __forceinline__ void VertexCull(
                Cta *cta,
                Tile *tile)
            {
                if (tile->vertex_id[LOAD][VEC] >= 0) {
                    // Row index on our GPU (for multi-gpu, vertex ids are striped across GPUs)
                    VertexId row_id = (tile->vertex_id[LOAD][VEC]) / cta->num_gpus;

                    if (Functor::CondVertex(row_id, cta->problem)) {
                        // ApplyVertex(row_id)
                        Functor::ApplyVertex(row_id, cta->problem);
                    }
                    else tile->vertex_id[LOAD][VEC] = -1;
                }

                // Next
                Iterate<LOAD, VEC + 1>::VertexCull(cta, tile);
            }

        };


        /**
         * Iterate next load
         */
        template <int LOAD, int dummy>
        struct Iterate<LOAD, LOAD_VEC_SIZE, dummy>
        {
            // InitFlags
            static __device__ __forceinline__ void InitFlags(Tile *tile)
            {
                Iterate<LOAD + 1, 0>::InitFlags(tile);
            }

            // VertexCull
            static __device__ __forceinline__ void VertexCull(Cta *cta, Tile *tile)
            {
                Iterate<LOAD + 1, 0>::VertexCull(cta, tile);
            }
        };



        /**
         * Terminate iteration
         */
        template <int dummy>
        struct Iterate<LOADS_PER_TILE, 0, dummy>
        {
            // InitFlags
            static __device__ __forceinline__ void InitFlags(Tile *tile) {}

            // VertexCull
            static __device__ __forceinline__ void VertexCull(Cta *cta, Tile *tile) {}

        };


        //---------------------------------------------------------------------
        // Interface
        //---------------------------------------------------------------------

        /**
         * Initializer
         */
        __device__ __forceinline__ void InitFlags()
        {
            Iterate<0, 0>::InitFlags(this);
        }

        /**
         * Culls vertices
         */
        __device__ __forceinline__ void VertexCull(Cta *cta)
        {
            Iterate<0, 0>::VertexCull(cta, this);
        }

    };




    //---------------------------------------------------------------------
    // Methods
    //---------------------------------------------------------------------

    /**
     * @brief CTA type default constructor
     */
    __device__ __forceinline__ Cta(
        VertexId                queue_index,
        int                     num_gpus,
        SmemStorage             &smem_storage,
        VertexId                *d_in,
        VertexId                *d_out,
        DataSlice               *problem,
        util::CtaWorkProgress   &work_progress,
        SizeT                   max_out_frontier) :

            queue_index(queue_index),
            num_gpus(num_gpus),
            raking_details(
                smem_storage.state.raking_elements,
                smem_storage.state.warpscan,
                0),
            smem_storage(smem_storage),
            d_in(d_in),
            d_out(d_out),
            problem(problem),
            work_progress(work_progress),
            max_out_frontier(max_out_frontier)
    {
    }


    /**
     * @brief Process a single, full tile.
     *
     * @param[in] cta_offset Offset within the CTA where we want to start the tile processing.
     * @param[in] guarded_elements The guarded elements to prevent the out-of-bound visit.
     */
    __device__ __forceinline__ void ProcessTile(
        SizeT cta_offset,
        const SizeT &guarded_elements = KernelPolicy::TILE_ELEMENTS)
    {
        Tile<KernelPolicy::LOG_LOADS_PER_TILE, KernelPolicy::LOG_LOAD_VEC_SIZE> tile;

        // Load tile
        util::io::LoadTile<
            KernelPolicy::LOG_LOADS_PER_TILE,
            KernelPolicy::LOG_LOAD_VEC_SIZE,
            KernelPolicy::THREADS,
            ProblemData::QUEUE_READ_MODIFIER,
            false>::LoadValid(
                tile.vertex_id,
                d_in,
                cta_offset,
                guarded_elements,
                (VertexId) -1);

        
        tile.VertexCull(this);          // using vertex visitation status (update discovered vertices)

        // Init valid flags and ranks
        tile.InitFlags();

        // Protect repurposable storage that backs both raking lanes and local cull scratch
        __syncthreads();

        // Scan tile of ranks, using an atomic add to reserve
        // space in the contracted queue, seeding ranks
        // Cooperative Scan (done)
        util::Sum<SizeT> scan_op;
        SizeT new_queue_offset = util::scan::CooperativeTileScan<KernelPolicy::LOAD_VEC_SIZE>::ScanTileWithEnqueue(
            raking_details,
            tile.ranks,
            work_progress.GetQueueCounter<SizeT>(queue_index + 1),
            scan_op);
        
        // Check updated queue offset for overflow due to redundant expansion
        if (new_queue_offset >= max_out_frontier) {
            work_progress.SetOverflow<SizeT>();
            util::ThreadExit();
        }

        // Scatter directly (without first contracting in smem scratch), predicated
        // on flags
        util::io::ScatterTile<
            KernelPolicy::LOG_LOADS_PER_TILE,
            KernelPolicy::LOG_LOAD_VEC_SIZE,
            KernelPolicy::THREADS,
            ProblemData::QUEUE_WRITE_MODIFIER>::Scatter(
                d_out,
                tile.vertex_id,
                tile.flags,
                tile.ranks);
    }
};


} // namespace vertex_map
} // namespace oprtr
} // namespace gunrock

// Leave this at the end of the file
// Local Variables:
// mode:c++
// c-file-style: "NVIDIA"
// End: