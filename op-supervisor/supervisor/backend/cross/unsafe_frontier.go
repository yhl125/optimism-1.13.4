package cross

import (
	"errors"
	"fmt"

	"github.com/ethereum-optimism/optimism/op-service/eth"
	"github.com/ethereum-optimism/optimism/op-supervisor/supervisor/types"
)

type UnsafeFrontierCheckDeps interface {
	FindBlockID(chainID eth.ChainID, blockNum uint64) (eth.BlockID, error)

	IsCrossUnsafe(chainID eth.ChainID, block eth.BlockID) error
	IsLocalUnsafe(chainID eth.ChainID, block eth.BlockID) error
}

// HazardUnsafeFrontierChecks verifies all the hazard blocks are either:
//   - already cross-unsafe.
//   - the first (if not first: local blocks to verify before proceeding)
//     local-unsafe block, after the cross-unsafe block.
func HazardUnsafeFrontierChecks(d UnsafeFrontierCheckDeps, hazards *HazardSet) error {
	for hazardChainID, hazardBlock := range hazards.Entries() {
		// Anything we depend on in this timestamp must be cross-unsafe already, or the first block after.
		err := d.IsCrossUnsafe(hazardChainID, hazardBlock.ID())
		if err != nil {
			if errors.Is(err, types.ErrFuture) {
				// Not already cross-unsafe, so we check if the block is local-unsafe
				// (a sanity check if part of the canonical chain).
				err = d.IsLocalUnsafe(hazardChainID, hazardBlock.ID())
				if err != nil {
					// can be ErrFuture (missing data) or ErrConflict (non-canonical)
					return fmt.Errorf("hazard block %s (chain %s) is not local-unsafe: %w", hazardBlock, hazardChainID, err)
				}
				// If it doesn't have a parent block, then there is no prior block required to be cross-safe
				if hazardBlock.Number > 0 {
					// Check that parent of hazardBlockID is cross-safe within view
					parent, err := d.FindBlockID(hazardChainID, hazardBlock.Number-1)
					if err != nil {
						return fmt.Errorf("failed to retrieve parent-block of hazard block %s (chain %s): %w", hazardBlock, hazardChainID, err)
					}
					if err := d.IsCrossUnsafe(hazardChainID, parent); err != nil {
						return fmt.Errorf("cannot rely on hazard-block %s (chain %s), parent block %s is not cross-unsafe: %w", hazardBlock, hazardChainID, parent, err)
					}
				}
			} else {
				return fmt.Errorf("failed to determine cross-derived of hazard block %s (chain %s): %w", hazardBlock, hazardChainID, err)
			}
		}
	}
	return nil
}
