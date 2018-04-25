/*
  This file is part of The Colony Network.

  The Colony Network is free software: you can redistribute it and/or modify
  it under the terms of the GNU General Public License as published by
  the Free Software Foundation, either version 3 of the License, or
  (at your option) any later version.

  The Colony Network is distributed in the hope that it will be useful,
  but WITHOUT ANY WARRANTY; without even the implied warranty of
  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
  GNU General Public License for more details.

  You should have received a copy of the GNU General Public License
  along with The Colony Network. If not, see <http://www.gnu.org/licenses/>.
*/

pragma solidity ^0.4.21;
pragma experimental "v0.5.0";
pragma experimental "ABIEncoderV2";

import "../lib/dappsys/auth.sol";
import "./Authority.sol";
import "./IColony.sol";
import "./EtherRouter.sol";
import "./ERC20Extended.sol";
import "./ColonyNetworkStorage.sol";
import "./IColonyNetwork.sol";
import "./PatriciaTree/PatriciaTreeProofs.sol";


// TODO: Can we handle all possible disputes regarding the very first hash that should be set?
// Currently, at the very least, we can't handle a dispute if the very first entry is disputed.
// A possible workaround would be to 'kick off' reputation mining with a known dummy state...
contract ReputationMiningCycle is PatriciaTreeProofs, DSMath {
  address colonyNetworkAddress;
  // TODO: Do we need both these mappings?
  mapping (bytes32 => mapping( uint256 => address[])) public submittedHashes;
  mapping (address => Submission) public reputationHashSubmissions;
  uint256 reputationMiningWindowOpenTimestamp;
  mapping (uint256 => Submission[]) public disputeRounds;

  // Tracks the number of submissions in each round that have completed their challenge, one way or the other.
  // This might be that they passed the challenge, it might be that their opponent passed (and therefore by implication,
  // they failed), or it might be that they timed out
  mapping (uint256 => uint256) nHashesCompletedChallengeRound;
  // A flaw with this is that if someone spams lots of nonsense transactions, then 'good' users still have to come along and
  // explicitly complete the pairings. But if they get the tokens that were staked in order to make the submission, maybe
  // that's okay...?

  // Number of unique hashes submitted
  uint256 public nSubmittedHashes = 0;
  uint256 public nInvalidatedHashes = 0;

  struct Submission {
    bytes32 proposedNewRootHash;          // The hash that the submitter is proposing as the next reputation hash
    uint256 nNodes;                       // The number of nodes in the reputation tree being proposed as the next reputation hash
    uint256 lastResponseTimestamp;        // If nonzero, the last time that a valid response was received corresponding to this
                                          // submission during the challenge process - either binary searching for the challenge,
                                          // responding to the challenge itself or submitting the JRH
    uint256 challengeStepCompleted;       // How many valid responses have been received corresponding to this submission during
                                          // the challenge process.
    bytes32 jrh;                          // The Justification Root Hash corresponding to this submission.
    bytes32 intermediateReputationHash;   // The hash this submission hash has as a leaf node in the tree the JRH is the root of where
                                          // this submission and its opponent differ for the first time.
    uint256 intermediateReputationNNodes; // The number of nodes in the reputation tree in the reputation state where this submission and
                                          // its opponent first differ.
    uint256 jrhNnodes;                    // The number of nodes in the tree the JRH is the root of.
    uint256 lowerBound;                   // During the binary search, the lowest index in the justification tree that might still be the
                                          // first place where the two submissions differ.
    uint256 upperBound;                   // During the binary search, the highest index in the justification tree that might still be the
                                          // first place where the two submissions differ.
                                          // When the binary search is complete, lowerBound and upperBound are equal
    uint256 provedPreviousReputationUID;  // If the disagreement between this submission and its opponent is related to the insertion of a
                                          // new leaf, the submitters also submit proof of a reputation in a state that the two agree on. The
                                          // UID that reputation has is stored here, and whichever submission proves the higher existing UID is
                                          // deemed correct, assuming it also matches the UID for the new reputation being inserted.
  }

  // Records for which hashes, for which addresses, for which entries have been accepted
  // Otherwise, people could keep submitting the same entry.
  mapping (bytes32 => mapping(address => mapping(uint256 => bool))) submittedEntries;

  /// @notice A modifier that checks that the supplied `roundNumber` is the final round
  /// @param roundNumber The `roundNumber` to check if it is the final round
  modifier finalDisputeRoundCompleted(uint roundNumber) {
    require (nSubmittedHashes - nInvalidatedHashes == 1);
    require (disputeRounds[roundNumber].length == 1); //i.e. this is the final round
    // Note that even if we are passed the penultimate round, which had a length of two, and had one eliminated,
    // and therefore 'delete' called in `invalidateHash`, the array still has a length of '2' - it's just that one
    // element is zeroed. If this functionality of 'delete' is ever changed, this will have to change too.
    _;
  }

  /// @notice A modifier that checks if the challenge corresponding to the hash in the passed `round` and `id` is open
  /// @param round The round number of the hash under consideration
  /// @param idx The index in the round of the hash under consideration
  modifier challengeOpen(uint256 round, uint256 idx) {
    // TODO: More checks that this is an appropriate time to respondToChallenge
    require(disputeRounds[round][idx].lowerBound == disputeRounds[round][idx].upperBound);
    _;
  }

  /// @notice A modifier that checks if the proposed entry is eligible. The more CLNY a user stakes, the more
  /// potential entries they have in a reputation mining cycle. This is effectively restricting the nonce range
  /// that is allowable from a given user when searching for a submission that will pass `withinTarget`. A user
  /// is allowed to use multiple entries in a single cycle, but each entry can only be used once per cycle, and
  /// if there are multiple entries they must all be for the same proposed Reputation State Root Hash with the
  /// same number of nodes.
  /// @param newHash The hash being submitted
  /// @param nNodes The number of nodes in the reputation tree that `newHash` is the root hash of
  /// @param entryIndex The number of the entry the submitter hash asked us to consider.
  modifier entryQualifies(bytes32 newHash, uint256 nNodes, uint256 entryIndex) {
    // TODO: Require minimum stake, that is (much) more than the cost required to defend the valid submission.
    // Here, the minimum stake is 10**15.
    require(entryIndex <= IColonyNetwork(colonyNetworkAddress).getStakedBalance(msg.sender) / 10**15);
    require(entryIndex > 0);
    if (reputationHashSubmissions[msg.sender].proposedNewRootHash != 0x0) {                // If this user has submitted before during this round...
      require(newHash == reputationHashSubmissions[msg.sender].proposedNewRootHash);       // ...require that they are submitting the same hash ...
      require(nNodes == reputationHashSubmissions[msg.sender].nNodes);      // ...require that they are submitting the same number of nodes for that hash ...
      require (submittedEntries[newHash][msg.sender][entryIndex] == false); // ... but not this exact entry
    }
    _;
  }

  /// @notice A modifier that checks if the proposed entry is within the current allowable submission window
  /// @dev A submission will only be accepted from a reputation miner if `keccak256(address, N, hash) < target`
  /// At the beginning of the submission window, the target is set to 0 and slowly increases to 2^256 - 1 after an hour
  modifier withinTarget(bytes32 newHash, uint256 entryIndex) {
    // Check the ticket is a winning one.
    // TODO Figure out how to uncomment the next line, but not break tests sporadically.
    // require((now-reputationMiningWindowOpenTimestamp) <= 3600);
    // x = floor(uint((2**256 - 1) / 3600)
    if (now - reputationMiningWindowOpenTimestamp <= 3600) {
      uint256 x = 32164469232587832062103051391302196625908329073789045566515995557753647122;
      uint256 target = (now - reputationMiningWindowOpenTimestamp ) * x;
      require(uint256(getEntryHash(msg.sender, entryIndex, newHash)) < target);
    }
    _;
  }

  /// @notice Get the hash for the corresponding entry.
  function getEntryHash(address submitter, uint256 entryIndex, bytes32 newHash) public pure returns (bytes32) {
    return keccak256(submitter, entryIndex, newHash);
  }

  /// @notice Constructor for this contract.
  function ReputationMiningCycle() public {
    colonyNetworkAddress = msg.sender;
    reputationMiningWindowOpenTimestamp = now;
  }

  /// @notice Submit a new reputation root hash
  /// @param newHash The proposed new reputation root hash
  /// @param nNodes Number of nodes in tree with root `newHash`
  /// @param entryIndex The entry number for the given `newHash` and `nNodes`
  function submitNewHash(bytes32 newHash, uint256 nNodes, uint256 entryIndex)
  entryQualifies(newHash, nNodes, entryIndex)
  withinTarget(newHash, entryIndex)
  public
  {
    // Limit the total number of miners allowed to submit a specific hash to 12
    require (submittedHashes[newHash][nNodes].length < 12);

    // If this is a new hash, increment nSubmittedHashes as such.
    if (submittedHashes[newHash][nNodes].length == 0) {
      nSubmittedHashes += 1;
      // And add it to the first disputeRound
      // NB if no other hash is submitted, no dispute resolution will be required.
      disputeRounds[0].push(Submission({
        proposedNewRootHash: newHash,
        jrh: 0x0,
        nNodes: nNodes,
        lastResponseTimestamp: 0,
        challengeStepCompleted: 0,
        lowerBound: 0,
        upperBound: 0,
        jrhNnodes: 0,
        intermediateReputationHash: 0x0,
        intermediateReputationNNodes: 0,
        provedPreviousReputationUID: 0
      }));
      // If we've got a pair of submissions to face off, may as well start now.
      if (nSubmittedHashes % 2 == 0) {
        disputeRounds[0][nSubmittedHashes-1].lastResponseTimestamp = now;
        disputeRounds[0][nSubmittedHashes-2].lastResponseTimestamp = now;
        /* disputeRounds[0][nSubmittedHashes-1].upperBound = disputeRounds[0][nSubmittedHashes-1].jrhNnodes; */
        /* disputeRounds[0][nSubmittedHashes-2].upperBound = disputeRounds[0][nSubmittedHashes-2].jrhNnodes; */
      }
    }

    reputationHashSubmissions[msg.sender] = Submission({
      proposedNewRootHash: newHash,
      jrh: 0x0,
      nNodes: nNodes,
      lastResponseTimestamp: 0,
      challengeStepCompleted: 0,
      lowerBound: 0,
      upperBound: 0,
      jrhNnodes: 0,
      intermediateReputationHash: 0x0,
      intermediateReputationNNodes: 0,
      provedPreviousReputationUID: 0
    });
    // And add the miner to the array list of submissions here
    submittedHashes[newHash][nNodes].push(msg.sender);
    // Note that they submitted it.
    submittedEntries[newHash][msg.sender][entryIndex] = true;
  }

  /// @notice Confirm a new reputation hash. The hash in question is either the only one that was submitted this cycle,
  /// or the last one standing after all others have been proved wrong.
  /// @param roundNumber The round number that the hash being confirmed is in as the only contendender. If only one hash was submitted, then this is zero.
  function confirmNewHash(uint256 roundNumber) public
  finalDisputeRoundCompleted(roundNumber)
  {
    // TODO: Require some amount of time to have passed (i.e. people have had a chance to submit other hashes)
    Submission storage submission = disputeRounds[roundNumber][0];
    IColonyNetwork(colonyNetworkAddress).setReputationRootHash(submission.proposedNewRootHash, submission.nNodes, submittedHashes[submission.proposedNewRootHash][submission.nNodes]);
    selfdestruct(colonyNetworkAddress);
  }

  /// @notice Invalidate a hash that has timed out relative to its opponent its current challenge step. Note that this can be called to 'invalidate'
  /// a nonexistent hash, if the round has an odd number of entrants and so the last hash is being given a bye to the next round.
  /// @param round The round number the hash being invalidated is in
  /// @param idx The index in the round that the hash being invalidated is in
  function invalidateHash(uint256 round, uint256 idx) public {
    // What we do depends on our opponent, so work out which index it was at in disputeRounds[round]
    uint256 opponentIdx = (idx % 2 == 1 ? idx-1 : idx + 1);
    uint256 nInNextRound;

    // We require either
    // 1. That we actually had an opponent - can't invalidate the last hash.
    // 2. This cycle had an odd number of submissions, which was larger than 1, and we're giving the last entry a bye to the next round.
    if (disputeRounds[round].length % 2 == 1 && disputeRounds[round].length == idx) {
      // This is option two above - note that because arrays are zero-indexed, if idx==length, then
      // this is the slot after the last entry, and so our opponentIdx will be the last entry
      // We just move the opponent on, and nothing else happens.

      // Ensure that the previous round is complete, and this entry wouldn't possibly get an opponent later on.
      require(nHashesCompletedChallengeRound[round-1] == disputeRounds[round-1].length);

      // Prevent us invalidating the final hash
      require(disputeRounds[round].length > 1);
      // Move opponent on to next round
      disputeRounds[round+1].push(disputeRounds[round][opponentIdx]);
      delete disputeRounds[round][opponentIdx];

      // Note the fact that this round has had another challenge complete
      nHashesCompletedChallengeRound[round] += 1;
      // Check if the hash we just moved to the next round is the second of a pairing that should now face off.
      nInNextRound = disputeRounds[round+1].length;

      if (nInNextRound % 2 == 0) {
        startPairingInRound(round+1);
      }
    } else {
      require(disputeRounds[round].length > opponentIdx);
      require(disputeRounds[round][opponentIdx].proposedNewRootHash != "");

      // Require that this is not better than its opponent.
      require(disputeRounds[round][opponentIdx].challengeStepCompleted >= disputeRounds[round][idx].challengeStepCompleted);
      require(disputeRounds[round][opponentIdx].provedPreviousReputationUID >= disputeRounds[round][idx].provedPreviousReputationUID);

      // Require that it has failed a challenge (i.e. failed to respond in time)
      require(now - disputeRounds[round][idx].lastResponseTimestamp >= 600); //'In time' is ten minutes here.

      // Work out whether we are invalidating just the supplied idx or its opponent too.
      bool eliminateOpponent = false;
      if (disputeRounds[round][opponentIdx].challengeStepCompleted == disputeRounds[round][idx].challengeStepCompleted &&
      disputeRounds[round][opponentIdx].provedPreviousReputationUID == disputeRounds[round][idx].provedPreviousReputationUID) {
        eliminateOpponent = true;
      }

      if (!eliminateOpponent) {
        // If here, then the opponent completed one more challenge round than the submission being invalidated or
        // proved a later UID was in the tree, so we don't know if they're valid or not yet. Move them on to the next round.
        disputeRounds[round+1].push(disputeRounds[round][opponentIdx]);
        delete disputeRounds[round][opponentIdx];
        // TODO Delete the hash(es) being invalidated?
        nInvalidatedHashes += 1;
        // Check if the hash we just moved to the next round is the second of a pairing that should now face off.
        nInNextRound = disputeRounds[round+1].length;
        if (nInNextRound % 2 == 0) {
          startPairingInRound(round+1);
        }
      } else {
        // Our opponent completed the same number of challenge rounds, and both have now timed out.
        nInvalidatedHashes += 2;
        // Punish the people who proposed our opponent
        IColonyNetwork(colonyNetworkAddress).punishStakers(submittedHashes[disputeRounds[round][opponentIdx].proposedNewRootHash][disputeRounds[round][opponentIdx].nNodes]);
      }

      // Note that two hashes have completed this challenge round (either one accepted for now and one rejected, or two rejected)
      nHashesCompletedChallengeRound[round] += 2;

      // Punish the people who proposed the hash that was rejected
      IColonyNetwork(colonyNetworkAddress).punishStakers(submittedHashes[disputeRounds[round][idx].proposedNewRootHash][disputeRounds[round][idx].nNodes]);
    }
    //TODO: Can we do some deleting to make calling this as cheap as possible for people?
  }

  /// @notice Respond to a binary search step, to eventually discover where two submitted hashes differ in their Justification trees.
  /// @param round The round number the hash we are responding on behalf of is in
  /// @param idx The index in the round that the hash we are responding on behalf of is in
  /// @param jhIntermediateValue The contents of the Justification Tree at the key given by `targetNode` (see function description). The value of `targetNode` is computed locally to establish what to submit to this function.
  /// @param branchMask The branchMask of the Merkle proof that `jhIntermediateValue` is the value at key `targetNode`
  /// @param siblings The siblings of the Merkle proof that `jhIntermediateValue` is the value at key `targetNode`
  function binarySearchForChallenge(uint256 round, uint256 idx, bytes jhIntermediateValue, uint branchMask, bytes32[] siblings) public {
    // TODO: Check this challenge is active.
    // This require is necessary, but not a sufficient check (need to check we have an opponent, at least).
    require(disputeRounds[round][idx].lowerBound!=disputeRounds[round][idx].upperBound);

    uint256 targetNode = add(disputeRounds[round][idx].lowerBound, sub(disputeRounds[round][idx].upperBound, disputeRounds[round][idx].lowerBound) / 2);
    bytes32 jrh = disputeRounds[round][idx].jrh;

    bytes memory targetNodeBytes = new bytes(32);
    assembly {
      mstore(add(targetNodeBytes, 0x20), targetNode)
    }

    verifyProof(jrh, targetNodeBytes, jhIntermediateValue, branchMask, siblings);
    // If verifyProof hasn't thrown, proof is correct.
    // Process the consequences
    processBinaryChallengeSearchResponse(round, idx, jhIntermediateValue, targetNode);
  }

  uint constant __ROUND__ = 0;
  uint constant __IDX__ = 1;
  uint constant __REPUTATION_BRANCH_MASK__ = 2;
  uint constant __AGREE_STATE_NNODES__ = 3;
  uint constant __AGREE_STATE_BRANCH_MASK__ = 4;
  uint constant __DISAGREE_STATE_NNODES__ = 5;
  uint constant __DISAGREE_STATE_BRANCH_MASK__ = 6;
  uint constant __PREVIOUS_NEW_REPUTATION_BRANCH_MASK__ = 7;
  uint constant __REQUIRE_REPUTATION_CHECK__ = 8;

  /// @notice Respond to challenge, to establish which (if either) of the two submissions facing off are correct.
  /// @param u A `uint256[9]` array. The elements of this array, in order are:
  /// * 1. The current round of the hash being responded on behalf of
  /// * 2. The current index in the round of the hash being responded on behalf of
  /// * 3. The branchMask of the proof that the reputation is in the reputation state tree for the reputation with the disputed change
  /// * 4. The number of nodes in the last reputation state that both submitted hashes agree on
  /// * 5. The branchMask of the proof that the last reputation state the submitted hashes agreed on is in this submitted hash's justification tree
  /// * 6. The number of nodes this hash considers to be present in the first reputation state the two hashes in this challenge disagree on
  /// * 7. The branchMask of the proof that reputation root hash of the first reputation state the two hashes in this challenge disagree on is in this submitted hash's justification tree
  /// * 8. The branchMask of the proof for the most recently added reputation state in this hash's state tree in the last reputation state the two hashes in this challenge agreed on
  /// * 9. A dummy variable that should be set to 0. If nonzero, transaction will still work but be slightly more expensive. For an explanation of why this is present, look at the corresponding solidity code.
  /// @param _reputationKey The key of the reputation being changed that the disagreement is over.
  /// @param reputationSiblings The siblings of the Merkle proof that the reputation corresponding to `_reputationKey` is in the reputation state before and after the disagreement
  /// @param agreeStateReputationValue The value of the reputation at key `_reputationKey` in the last reputation state the submitted hashes agreed on
  /// @param agreeStateSiblings The siblings of the Merkle proof that the last reputation state the submitted hashes agreed on is in this submitted hash's justification tree
  /// @param disagreeStateReputationValue The value of the reputation at key `_reputationKey` in the first reputation state the submitted hashes disagree on
  /// @param disagreeStateSiblings The siblings of the Merkle proof that the first reputation state the submitted hashes disagreed on is in this submitted hash's justification tree
  /// @param previousNewReputationKey The key of the newest reputation added to the reputation tree in the last reputation state the submitted hashes agree on
  /// @param previousNewReputationValue The value of the newest reputation added to the reputation tree in the last reputation state the submitted hashes agree on
  /// @param previousNewReputationSiblings The siblings of the Merkle proof of the newest reputation added to the reputation tree in the last reputation state the submitted hashes agree on
  /// @dev If you know that the disagreement doesn't involve a new reputation being added, the arguments corresponding to the previous new reputation can be zeroed, as they will not be used. You must be sure
  /// that this is the case, however, otherwise you risk being found incorrect. Zeroed arguments will result in a cheaper call to this function.
  function respondToChallenge(
    uint256[9] u, //An array of 9 UINT Params, ordered as given above.
    bytes _reputationKey,
    bytes32[] reputationSiblings,
    bytes agreeStateReputationValue,
    bytes32[] agreeStateSiblings,
    bytes disagreeStateReputationValue,
    bytes32[] disagreeStateSiblings,
    bytes previousNewReputationKey,
    bytes previousNewReputationValue,
    bytes32[] previousNewReputationSiblings
  ) public
    challengeOpen(u[__ROUND__], u[__IDX__])
  {
    u[__REQUIRE_REPUTATION_CHECK__] = 0;
    // TODO: More checks that this is an appropriate time to respondToChallenge (maybe in modifier);
    /* bytes32 jrh = disputeRounds[round][idx].jrh; */
    // The contract knows
    // 1. the jrh for this submission
    // 2. The first index where this submission and its opponent differ.
    // Need to prove
    // 1. The reputation that is updated that we disagree on's value, before the first index
    //    where we differ, and in the first index where we differ.
    // 2. That no other changes are made to the reputation state. The proof for those
    //    two reputations in (1) is therefore required to be the same.
    // 3. That our 'after' value is correct. This is done by doing the calculation on-chain, perhaps
    //    after looking up the corresponding entry in the reputation update log (the alternative is
    //    that it's a decay calculation - not yet implemented.)

    // Check the supplied key is appropriate.
    checkKey(u[__ROUND__], u[__IDX__], _reputationKey);

    // Prove the reputation's starting value is in some state, and that state is in the appropriate index in our JRH
    proveBeforeReputationValue(u, _reputationKey, reputationSiblings, agreeStateReputationValue, agreeStateSiblings);

    // Prove the reputation's final value is in a particular state, and that state is in our JRH in the appropriate index (corresponding to the first disagreement between these miners)
    // By using the same branchMask and siblings, we know that no other changes to the reputation state tree have been slipped in.
    proveAfterReputationValue(u, _reputationKey, reputationSiblings, disagreeStateReputationValue, disagreeStateSiblings);

    // Perform the reputation calculation ourselves.
    performReputationCalculation(u, agreeStateReputationValue, disagreeStateReputationValue, previousNewReputationValue);

    // If necessary, check the supplied previousNewRepuation is, in fact, in the same reputation state as the agreeState
    if (u[__REQUIRE_REPUTATION_CHECK__]==1) {
      checkPreviousReputationInState(
        u,
        _reputationKey,
        reputationSiblings,
        agreeStateReputationValue,
        agreeStateSiblings,
        previousNewReputationKey,
        previousNewReputationValue,
        previousNewReputationSiblings);
      saveProvedReputation(u, previousNewReputationValue);
    }

    // If everthing checked out, note that we've responded to the challenge.
    disputeRounds[u[__ROUND__]][u[__IDX__]].challengeStepCompleted += 1;
    disputeRounds[u[__ROUND__]][u[__IDX__]].lastResponseTimestamp = now;

    // Safety net?
    /* if (disputeRounds[round][idx].challengeStepCompleted==disputeRounds[round][opponentIdx].challengeStepCompleted){
      // Freeze the reputation mining system.
    } */

  }
  /// @notice Submit the Justification Root Hash (JRH) for a submitted reputation hash.
  /// @param round The round that the hash is currently in.
  /// @param index The index in the round that the hash is currently in
  /// @param jrh The JRH being submitted
  /// @param branchMask1 The branchmask for the Merkle proof that the currently accepted reputation state (given by `ColonyNetwork.getReputationRootHash()` + `ColonyNetwork.getReputationRootHashNNodes()`, where `+` is concatenation) is at key 0x000..000 in the submitted JRH
  /// @param siblings1 The siblings for the same Merkle proof
  /// @param branchMask2 The branchmask for the Merkle proof that the proposed new reputation state is at the key corresponding to the number of transactions expected in this update in the submitted JRH. This key should be the number of decay transactions plus the number of transactions the log indicates are to happen.
  /// @param siblings2 The siblings for the same Merkle proof
  /// @dev The majority of calls to this function will have `round` equal to `0`. The one exception to this is when a submitted hash is given a bye in the first round, in which case `round` will be equal to `1`.
  function submitJRH(
    uint256 round,
    uint256 index,
    bytes32 jrh,
    uint branchMask1,
    bytes32[] siblings1,
    uint branchMask2,
    bytes32[] siblings2
  ) public
  {
    // Require we've not submitted already.
    require(disputeRounds[round][index].jrh == 0x0);

    // Check the proofs for the JRH
    require(checkJRHProof1(jrh, branchMask1, siblings1));
    require(checkJRHProof2(round, index, jrh, branchMask2, siblings2));

    // Store their JRH
    disputeRounds[round][index].jrh = jrh;
    disputeRounds[round][index].lastResponseTimestamp = now;
    disputeRounds[round][index].challengeStepCompleted += 1;

    // Set bounds for first binary search if it's going to be needed
    disputeRounds[round][index].upperBound = disputeRounds[round][index].jrhNnodes;
  }

  /////////////////////////
  // Internal functions
  /////////////////////////

  function processBinaryChallengeSearchResponse(uint256 round, uint256 idx, bytes jhIntermediateValue, uint256 targetNode) internal {
    disputeRounds[round][idx].lastResponseTimestamp = now;
    disputeRounds[round][idx].challengeStepCompleted += 1;
    // Save our intermediate hash
    bytes32 intermediateReputationHash;
    uint256 intermediateReputationNNodes;
    assembly {
      intermediateReputationHash := mload(add(jhIntermediateValue, 0x20))
      intermediateReputationNNodes := mload(add(jhIntermediateValue, 0x40))
    }
    disputeRounds[round][idx].intermediateReputationHash = intermediateReputationHash;
    disputeRounds[round][idx].intermediateReputationNNodes = intermediateReputationNNodes;

    uint256 opponentIdx = (idx % 2 == 1 ? idx-1 : idx + 1);
    if (disputeRounds[round][opponentIdx].challengeStepCompleted == disputeRounds[round][idx].challengeStepCompleted ) {
      // Our opponent answered this challenge already.
      // Compare our intermediateReputationHash to theirs to establish how to move the bounds.
      processBinaryChallengeSearchStep(round, idx, targetNode);
    }
  }

  function processBinaryChallengeSearchStep(uint256 round, uint256 idx, uint256 targetNode) internal {
    uint256 opponentIdx = (idx % 2 == 1 ? idx-1 : idx + 1);
    if (
      disputeRounds[round][opponentIdx].intermediateReputationHash == disputeRounds[round][idx].intermediateReputationHash &&
      disputeRounds[round][opponentIdx].intermediateReputationNNodes == disputeRounds[round][idx].intermediateReputationNNodes
      )
    {
      disputeRounds[round][idx].lowerBound = targetNode + 1;
      disputeRounds[round][opponentIdx].lowerBound = targetNode + 1;
    } else {
      // NB no '-1' to mirror the '+1' above in the other bound, because
      // we're looking for the first index where these two submissions differ
      // in their calculations - they disagreed for this index, so this might
      // be the first index they disagree about
      disputeRounds[round][idx].upperBound = targetNode;
      disputeRounds[round][opponentIdx].upperBound = targetNode;
    }
    // We need to keep the intermediate hashes so that we can figure out what type of dispute we are resolving later
    // If the number of nodes in the reputation state are different, then we are disagreeing on whether this log entry
    // corresponds to an existing reputation entry or not.
    // If the hashes are different, then it's a calculation error.

    // Our opponent responded to this step of the challenge before we did, so we should
    // reset their 'last response' time to now, as they aren't able to respond
    // to the next challenge before they know what it is!
    disputeRounds[round][opponentIdx].lastResponseTimestamp = now;
  }

  function checkKey( uint256 round, uint256 idx, bytes memory _reputationKey) internal {
    // If the state transition we're checking is less than the number of nodes in the currently accepted state, it's a decay transition (TODO: not implemented)
    // Otherwise, look up the corresponding entry in the reputation log.
    uint256 updateNumber = disputeRounds[round][idx].lowerBound - 1;
    bytes memory reputationKey = new bytes(20+32+20);
    reputationKey = _reputationKey;
    address colonyAddress;
    address userAddress;
    uint256 skillId;
    assembly {
        colonyAddress := mload(add(reputationKey,20)) // 20, not 32, because we're copying in to a slot that will be interpreted as an address.
                                              // which will truncate the leftmost 12 bytes
        skillId := mload(add(reputationKey, 52))
        userAddress := mload(add(reputationKey,72))   // 72, not 84, for the same reason as above. Is this being too clever? I don't think there are
                                              // any unintended side effects here, but I'm not quite confortable enough with EVM's stack to be sure.
                                              // Not sure what the alternative would be anyway.
    }
    bool decayCalculation = false;
    if (decayCalculation) {
    } else {
      address logUserAddress;
      uint256 logSkillId;
      address logColonyAddress;

      (logUserAddress, , logSkillId, logColonyAddress, , ) = IColonyNetwork(colonyNetworkAddress).getReputationUpdateLogEntry(updateNumber, false);
      require(logUserAddress == userAddress);
      require(logColonyAddress == colonyAddress);
      require(logSkillId == skillId);
    }
  }

  function proveBeforeReputationValue(uint256[9] u, bytes _reputationKey, bytes32[] reputationSiblings, bytes agreeStateReputationValue, bytes32[] agreeStateSiblings) internal {
    bytes32 jrh = disputeRounds[u[__ROUND__]][u[__IDX__]].jrh;
    uint256 lastAgreeIdx = disputeRounds[u[__ROUND__]][u[__IDX__]].lowerBound - 1; // We binary searched to the first disagreement, so the last agreement is the one before.
    uint256 reputationValue;
    assembly {
        reputationValue := mload(add(agreeStateReputationValue, 32))
    }

    bytes32 reputationRootHash = getImpliedRoot(_reputationKey, agreeStateReputationValue, u[__REPUTATION_BRANCH_MASK__], reputationSiblings);
    bytes memory jhLeafValue = new bytes(64);
    bytes memory lastAgreeIdxBytes = new bytes(32);
    assembly {
      mstore(add(jhLeafValue, 0x20), reputationRootHash)
      let x := mload(add(u, mul(32,3))) // 3 = __AGREE_STATE_NNODES__. Constants not supported by inline solidity
      mstore(add(jhLeafValue, 0x40), x)
      mstore(add(lastAgreeIdxBytes, 0x20), lastAgreeIdx)
    }
    // Prove that state is in our JRH, in the index corresponding to the last state that the two submissions
    // agree on.
    bytes32 impliedRoot = getImpliedRoot(lastAgreeIdxBytes, jhLeafValue, u[__AGREE_STATE_BRANCH_MASK__], agreeStateSiblings);

    if (reputationValue == 0 && impliedRoot != jrh) {
      // This implies they are claiming that this is a new hash.
      return;
    }
    require(impliedRoot == jrh);
    // They've actually verified whatever they claimed. We increment their challengeStepCompleted by one to indicate this.
    // In the event that our opponent lied about this reputation not existing yet in the tree, they will both complete
    // a call to respondToChallenge, but we will have a higher challengeStepCompleted value, and so they will be the ones
    // eliminated.
    disputeRounds[u[__ROUND__]][u[__IDX__]].challengeStepCompleted += 1;
    // I think this trick can be used exactly once, and only because this is the last function to be called in the challege,
    // and I'm choosing to use it here. I *think* this is okay, because the only situation
    // where we don't prove anything with merkle proofs in this whole dance is here.
  }

  function proveAfterReputationValue(uint256[9] u, bytes _reputationKey, bytes32[] reputationSiblings, bytes disagreeStateReputationValue, bytes32[] disagreeStateSiblings) internal {
    bytes32 jrh = disputeRounds[u[__ROUND__]][u[__IDX__]].jrh;
    uint256 firstDisagreeIdx = disputeRounds[u[__ROUND__]][u[__IDX__]].lowerBound;
    bytes32 reputationRootHash = getImpliedRoot(_reputationKey, disagreeStateReputationValue, u[__REPUTATION_BRANCH_MASK__], reputationSiblings);
    // Prove that state is in our JRH, in the index corresponding to the last state that the two submissions
    // agree on.
    bytes memory jhLeafValue = new bytes(64);
    bytes memory firstDisagreeIdxBytes = new bytes(32);

    assembly {
      mstore(add(jhLeafValue, 0x20), reputationRootHash)
      let x := mload(add(u, mul(32,5))) // 5 = __DISAGREE_STATE_NNODES__. Constants not supported by inline solidity.
      mstore(add(jhLeafValue, 0x40), x)
      mstore(add(firstDisagreeIdxBytes, 0x20), firstDisagreeIdx)
    }

    verifyProof(jrh, firstDisagreeIdxBytes, jhLeafValue, u[__DISAGREE_STATE_BRANCH_MASK__], disagreeStateSiblings);
  }

  function performReputationCalculation(uint256[9] u, bytes agreeStateReputationValueBytes, bytes disagreeStateReputationValueBytes, bytes previousNewReputationValueBytes) internal {
    // TODO: Possibility of decay calculation
    uint reputationTransitionIdx = disputeRounds[u[__ROUND__]][u[__IDX__]].lowerBound - 1;
    int256 amount;
    uint256 agreeStateReputationValue;
    uint256 disagreeStateReputationValue;
    uint256 agreeStateReputationUID;
    uint256 disagreeStateReputationUID;

    assembly {
        agreeStateReputationValue := mload(add(agreeStateReputationValueBytes, 32))
        disagreeStateReputationValue := mload(add(disagreeStateReputationValueBytes, 32))
        agreeStateReputationUID := mload(add(agreeStateReputationValueBytes, 64))
        disagreeStateReputationUID := mload(add(disagreeStateReputationValueBytes, 64))
    }

    if (agreeStateReputationUID != 0) {
      // i.e. if this was an existing reputation, then require that the ID hasn't changed.
      // TODO: Situation where it is not an existing reputation
      require(agreeStateReputationUID==disagreeStateReputationUID);
    } else {
      uint256 previousNewReputationUID;
      assembly {
        previousNewReputationUID := mload(add(previousNewReputationValueBytes, 64))
      }
      require(previousNewReputationUID+1 == disagreeStateReputationUID);
      // Flag that we need to check that the reputation they supplied is in the 'agree' state.
      // This feels like it might be being a bit clever, using this array to pass a 'return' value out of
      // this function, without adding a new variable to the stack in the parent function...
      u[__REQUIRE_REPUTATION_CHECK__] = 1;
    }

    (, amount, , , ,) = IColonyNetwork(colonyNetworkAddress).getReputationUpdateLogEntry(reputationTransitionIdx, false);
    // TODO: Is this safe? I think so, because even if there's over/underflows, they should
    // still be the same number.
    require(int(agreeStateReputationValue)+amount == int(disagreeStateReputationValue));
  }

  function checkPreviousReputationInState(
    uint256[9] u,
    bytes _reputationKey,
    bytes32[] reputationSiblings,
    bytes agreeStateReputationValue,
    bytes32[] agreeStateSiblings,
    bytes previousNewReputationKey,
    bytes previousNewReputationValue,
    bytes32[] previousNewReputationSiblings)
  internal
  {
    uint256 lastAgreeIdx = disputeRounds[u[__ROUND__]][u[__IDX__]].lowerBound - 1; // We binary searched to the first disagreement, so the last agreement is the one before

    bytes32 reputationRootHash = getImpliedRoot(previousNewReputationKey, previousNewReputationValue, u[__PREVIOUS_NEW_REPUTATION_BRANCH_MASK__], previousNewReputationSiblings);
    bytes memory jhLeafValue = new bytes(64);
    bytes memory lastAgreeIdxBytes = new bytes(32);
    assembly {
      mstore(add(jhLeafValue, 0x20), reputationRootHash)
      let x := mload(add(u, mul(32,3))) // 3 = __AGREE_STATE_NNODES__. Constants not supported by inline assembly
      mstore(add(jhLeafValue, 0x40), x)
      mstore(add(lastAgreeIdxBytes, 0x20), lastAgreeIdx)
    }
    // Prove that state is in our JRH, in the index corresponding to the last state that the two submissions agree on
    bytes32 impliedRoot = getImpliedRoot(lastAgreeIdxBytes, jhLeafValue, u[__AGREE_STATE_BRANCH_MASK__], agreeStateSiblings);
    require(impliedRoot == disputeRounds[u[__ROUND__]][u[__IDX__]].jrh);
  }

  function saveProvedReputation(uint256[9] u, bytes previousNewReputationValue) internal {
    uint256 previousReputationUID;
    assembly {
      previousReputationUID := mload(add(previousNewReputationValue,0x40))
    }
    // Save the index for tiebreak scenarios later.
    disputeRounds[u[__ROUND__]][u[__IDX__]].provedPreviousReputationUID = previousReputationUID;
  }

  function checkJRHProof1(bytes32 jrh, uint branchMask1, bytes32[] siblings1) internal returns (bool result) {
    // Proof 1 needs to prove that they started with the current reputation root hash
    bytes32 reputationRootHash = IColonyNetwork(colonyNetworkAddress).getReputationRootHash();
    uint256 reputationRootHashNNodes = IColonyNetwork(colonyNetworkAddress).getReputationRootHashNNodes();
    bytes memory jhLeafValue = new bytes(64);
    bytes memory zero = new bytes(32);
    assembly {
      mstore(add(jhLeafValue, 0x20), reputationRootHash)
      mstore(add(jhLeafValue, 0x40), reputationRootHashNNodes)
    }
    return verifyProof(jrh, zero, jhLeafValue, branchMask1, siblings1);
  }

  function checkJRHProof2(uint round, uint index, bytes32 jrh, uint branchMask2, bytes32[] siblings2) internal returns (bool result) {
    // Proof 2 needs to prove that they finished with the reputation root hash they submitted, and the
    // key is the number of updates in the reputation update log (implemented)
    // plus the number of nodes in the last accepted update, each of which will have decayed once (not implemented)
    // TODO: Account for decay calculations
    uint256 nUpdates = IColonyNetwork(colonyNetworkAddress).getReputationUpdateLogLength(false);
    bytes memory nUpdatesBytes = new bytes(32);
    disputeRounds[round][index].jrhNnodes = nUpdates + 1;
    bytes32 submittedHash = disputeRounds[round][index].proposedNewRootHash;
    uint256 submittedHashNNodes = disputeRounds[round][index].nNodes;
    bytes memory jhLeafValue = new bytes(64);
    assembly {
      mstore(add(jhLeafValue, 0x20), submittedHash)
      mstore(add(jhLeafValue, 0x40), submittedHashNNodes)
      mstore(add(nUpdatesBytes, 0x20), nUpdates)
    }
    return verifyProof(jrh, nUpdatesBytes, jhLeafValue, branchMask2, siblings2);
  }

  function startMemberOfPair(uint256 roundNumber, uint256 index) internal {
    disputeRounds[roundNumber][index].lastResponseTimestamp = now;
    disputeRounds[roundNumber][index].upperBound = disputeRounds[roundNumber][index].jrhNnodes;
    disputeRounds[roundNumber][index].lowerBound = 0;
    disputeRounds[roundNumber][index].provedPreviousReputationUID = 0;
    if (disputeRounds[roundNumber][index].jrh != 0x0) {
      // If this submission has a JRH, we give ourselves credit for it in the next round - it's possible
      // that a submission got a bye without submitting a JRH, which will not have this starting '1'.
      disputeRounds[roundNumber][index].challengeStepCompleted = 1;
    } else {
      disputeRounds[roundNumber][index].challengeStepCompleted = 0;
    }
  }

  function startPairingInRound(uint256 roundNumber) internal {
    uint256 nInRound = disputeRounds[roundNumber].length;
    startMemberOfPair(roundNumber, nInRound-1);
    startMemberOfPair(roundNumber, nInRound-2);
  }
}
