// Copyright 2018-2021 VMware, Inc., Microsoft Inc., Carnegie Mellon University, ETH Zurich, and University of Washington
// SPDX-License-Identifier: BSD-2-Clause

include "../lib/Base/total_order.i.dfy"
include "../lib/Base/Maps.i.dfy"
include "IndirectionTable.i.dfy"
include "AllocationTable.i.dfy"
include "AllocationTableMachine.i.dfy"
include "MsgHistory.i.dfy"
include "Message.s.dfy"
include "Interp.s.dfy"
include "BranchTree.i.dfy"
include "MsgSeq.i.dfy"

/*
a Splinter tree consists of:
- Trunk nodes. These have routing information, and link to B+trees that store actual messages.
  Links include filters that select particular keys, neutralize old messages.
- Immutable B+trees, allocated in big (many-MB?) chunks, store a batch of messages from
  a rectangle of some keyrange * sequence number window.
- Flush is two steps:
  - "Pushdown"? logically pushes a sub-rectangle of messages to a child trunk node, done by
    forwarding the references.
  - Compact rewrites content from input B+trees to an output B+tree, pushing the input trees
    closer to being freed. This is garbage collection.
- Lookup must:
  - follow an appropriate trunk path
  - Collect non-excluded messages from every linked B+tree
- Allocation must account for:
  - Used trunk nodes. (One CU allocated in an entire AU, evidently.)
  - Batches of CUs (AUs) used to build a B+tree.

So Splintertree.lookup is a series of trunk nodes, their CUs,
  plus for each a B+tree.lookup, which itself is a series of CUs.

  So maybe the thing to do is stub out the B+tree interface that this thing is going to
  take as a submodule.

  Also, how are we going to do:
  * dependency tracking for when we can free B+trees
    * how do we write down that change in allocation?
    * at this layer, maybe define the Betree allocation as the union of the reachable B+tree
      allocations?
  * indirection table?  each time we replace a trunk node, we want to
    - allocate a new CU to store it in
    - link the parent to this new CU
    - This process doesn't need reference counting, but it does affect the reference
      counts for the B+trees. WAIT YES IT DOES it's a Bedag -- for clone.
    - We do need to adjust allocations when we make the swap.

  How to B+trees get incrementally constructed?
    - At this layer in the refinement stack, maybe they just get incrementally allocated,
    in a way that the increments never get frozen?

  Allocation strategy.
  * At this refinement layer, we'll identify the
    - reachable trunk CUs (Identified by lookups? gulp) and
    - reachable B+tree CU sets.
    - and then our sb.alloc will reflect those sets whenever we freeze.

  * In next layer down, we can't require faulting the entire tree in to compute the alloc,
    so we'll attach it to invariants that track:
    - an allocation table read from the disk representing the base (persistent) image
    - When we de/allocate a trunk CU or B+tree set<CU>, we'll subtract/add them to the table
  Will the invariant connection be via a recursive definition? Gulp. Definitely not if
    trunks form a DAG.
  Will the invariant connection simply be induction invariants that
    - every reachable thing is in the set
    - everything in the set is reachable (ew)
    - no reachable thing overlaps with another reachable thing (ew ew)
  Maybe
    - we ghostily know the set of reachable B+trees. (Can we marshal ghost data across a restart?)
    - we ghostily know the set of reachable trunks.
    - we maintain an invariant between the set of IReads sets of those data structures
    that gives mutual disjointness and that they union to the allocation set.

  Indirection table:
  - There are two kinds of things that need refcounting: B+trees and trunks.
  - We used to think we'd reference count allocated CUs. That doesn't make any sense.
  - But how do we *name* the B+trees and name the trunks? By their roots? Why not? CUs are
    disjoint, so root CUs are unique... and that's also how they're named in pointers.

  - How many trunks are there? How many B+trees?
    - I think we're going to end up storing a table in memory that's shaped very much
    like an allocation table, but has counters.
    - It's going to count refs to CUs.
      - Can we represent this one relationally against a whole DiskView? I think we can!
      forall reachable trunks forall b+trees count once?
    - And then another table is going to connect CU roots to all the CUs (or rather all the AUs)
      for a given data structure.
      - in particular, this second table, at this layer, can be represented by just reading the
      underlying data structures!

*/

// trunk nodes and IndirectionTable (makes trunk nodes behave like they're mutable)
// immutable b+trees
// Index/leaf nodes in the b+trees

module SplinterTreeMachineMod {
  import opened Options
  import opened Sequences
  import opened Maps
  import opened ValueMessage
  import opened KeyType
  import opened InterpMod
  import opened DiskTypesMod
  import opened AllocationMod
  import opened MsgHistoryMod
  import AllocationTableMachineMod
  import IndirectionTableMod
  import CacheIfc
  import BranchTreeMod
  import MsgSeqMod

  // TODO: Rename this module
  datatype Superblock = Superblock(
    indTbl: IndirectionTableMod.Superblock,
    endSeq: LSN,
    // Sowmya -- We need this no??
    root: Option<CU>)

  function MkfsSuperblock() : Superblock
  {
    Superblock(IndirectionTableMod.EmptySuperblock(), 0, None)
  }


  function parseTrunkNode(b: UninterpretedDiskPage) : Option<TrunkNode>
      // TODO

  // Parses CU units to BranchNodes that we can use
  function CUToTrunkNode(cu : CU, cache: CacheIfc.Variables) : Option<TrunkNode>
    {
        var diskPage := CacheIfc.ReadValue(cache, cu);
        if diskPage == None
        then
          None
        else
          parseTrunkNode(diskPage.value)
    }


  function marshalTrunkNode(node: TrunkNode) : UninterpretedDiskPage
      // f

  type TrunkId = nat
  function RootId() : TrunkId { 0 }

  // Note that branches are ordered from oldest to youngest. So 0 is the oldest branch and 1 is the youngest
  // activeBranches tells us the lowest index of an active branch tree for the corresponding child
  datatype TrunkNode = TrunkNode(branches : seq<BranchTreeMod.Variables>,
                                     children : seq<TrunkNode>,
                                     pivots : seq<BranchTreeMod.Key>,
                                     activeBranches : seq<nat>)
  {
    predicate WF()
    {
      && |children| == |activeBranches|
      // activeBranches can only point to actual branch trees
      && forall i :: ( (0 <= i < |activeBranches|) ==> (0 <= activeBranches[i] < |branches|))
      // WF conditions on the pivots
      && (|children| > 0) ==> (|children| == |pivots| + 1)
      && forall pivot :: (1 <= pivot < |pivots| && pivots[pivot - 1] < pivots[pivot])
    }

    // TODO: Collapse all the in all the branch nodes in this level
    function AllMessages() : map<Key, Message>

  }

  // Three states : STatble persistent disk state , ephemeral working state and a frozen ephemeral state
  // that's being written out

  // Is it gross that my Betree knows about the three views?
  // The alternative would be for some outer module to instantiate
  // me three times, and then maintain allocation information on
  // my behalf. How would that look?
  // It would look like Program doing a "Freeze" step that captures the current
  // (indTbl, nextSeq, alloc).
  // Alloc would be non-opaque (so Program could protect the allocation against
  // Journal and ephemeral Btree while freeze gets written to disk).
  // indTbl must be kinda-visible, because someone has to alloc it and escort the dirty
  // pages to disk.
  // Someone has to figure out when this frozen state is all clean (perhaps
  // using some dirty bits in alloc?)
  // None of that seems like a great layering economy. Let's leave Frozen in here.
  //
  // The result is that, down here, we have to protect two separate allocs, I guess.
  datatype Frozen = Idle | Frozen(
    indTbl: IndirectionTableMod.IndirectionTable,
    endSeq: LSN)

  datatype Variables = Variables(
    // Write Opt file systems allows us to leverage immutability to simplfy reasoning about crash safety using cow
    // Add a layer of indirection over Immutable splinter tree. This indirection table adds mutability over the tree
    indTbl: IndirectionTableMod.IndirectionTable,
    memBuffer: map<Key, Message>,  // Real Splinter (next layer down? :v) has >1 memBuffers so we can be inserting at the front while flushing at the back.
    // TODO add a membuffer to record LSN; a frozen-like transition to keep one membuffer available
    // for filling while packing the other into a b+tree in the top trunk.
    // OR just have freeze drain the membuffer, introducing a write hiccup every 20GB.
    nextSeq: LSN,  // exclusive
    frozen: Frozen,
    root : Option<CU> // The CU to the root of the trunk tree
  )
  {
      function BetreeEndsLSNExclusive() : LSN {
        nextSeq
      }

      function getRoot() : Option<CU> {
        root
      }
  }

  // We need this for lookup no?
  function FindCorrectBranch(v : Variables, k: Key) : Option<TrunkPath>

  // TODO replay log!
  predicate Start(v: Variables, v': Variables, cache: CacheIfc.Variables, sb: Superblock)
  {
    // Note predicate-style assignment of some fields of v'
    && IndirectionTableMod.DurableAt(v'.indTbl, cache, sb.indTbl) // Parse ind tbl from cache
    && v'.memBuffer == map[]
    && v'.nextSeq == sb.endSeq
    && v'.frozen == Idle
  }

  datatype NodeAssignment = NodeAssignment(id: TrunkId, cu: CU, node: TrunkNode)
  {
    predicate InIndTable(v: Variables)
    {
      && id in v.indTbl
      && v.indTbl[id] == cu
    }

    predicate ValidCU(cache : CacheIfc.Variables)
    {
      && var unparsedPage := CacheIfc.ReadValue(cache, cu);
      && unparsedPage.Some?
      && Some(node) == parseTrunkNode(unparsedPage.value)
    }

    predicate Valid(v: Variables, cache: CacheIfc.Variables)
    {
      && InIndTable(v)
      && ValidCU(cache)
    }

  }

  // TODO find in library: Done look at Message.s.dfy
  // function CombineMessages(newer: Message, older: Message) : Message
  // function EvaluateMessage(m: Message) : Value
  // function MakeValueMessage(value:Value) : Message

  // QUESTION : What does this do???
  // TODO: Change this to actually fold the messages
  // function MessageFolder(newer: map<Key,Message>, older: map<Key,Message>) : map<Key,Message>
  // {
	// 	map x : Key | (x in newer.Keys + older.Keys) ::
  //     if x in newer
  //     then if x in older
  //       then CombineMessages(newer[x], older[x])
  //       else newer[x]
  //     else older[x]
  // }

  datatype TrunkStep = TrunkStep(
    // The information about the trunk node of this step
    na: NodeAssignment,
    // The Branch Receipts of a lookup from all the branches of this trunk node
    branchReceipts: seq<BranchTreeMod.BranchReceipt>,
    // The messages accumulated in till the previous trunkStep
    accumulatedMsgs: seq<Message>)
  {
    predicate WF()
    {
      && na.node.WF()
      && ( forall i :: 0 <= i < |branchReceipts| && branchReceipts[i].branchTree.WF() )
      // We have all the receipts. Does this go in WF() or Valid()??
      && |branchReceipts| == |na.node.branches|
    }

    predicate Valid(v: Variables, cache: CacheIfc.Variables) {
      && na.Valid(v, cache)
      && ( forall i :: 0 <= i < |branchReceipts| && branchReceipts[i].Valid(cache) )
      // Note: Here we require one to one correspondance between the node's branches and the corresponding look up receipt
      && (forall i :: 0 <= i < |branchReceipts| && na.node.branches[i] == branchReceipts[i].branchTree)
    }

    function MsgSeqRecurse(count : nat) : (out: seq<Message>)
    {
      if count == 0
      then
        []
      else
        var currBranchVal := branchReceipts[count-1].branchPath.Decode();
        ( if currBranchVal.Some?
        then
          [currBranchVal.value]
        else [] )
        + MsgSeqRecurse(count - 1)

    }

    // Messages in all the branch receipts at this layer
    function MsgSeq() : seq<Message>
    {
      MsgSeqRecurse(|branchReceipts|)
    }
  }

  datatype TrunkPath = TrunkPath(k: Key, steps: seq<TrunkStep>)
  {
    predicate {:opaque} ValidPrefix(cache: CacheIfc.Variables) {
      && forall i :: (0 < i < |steps|) && steps[i].na.node in steps[i-1].na.node.children
    }

    function msgSeqRecurse(count : nat) : (out : seq<Message>)
    {
      if count == 0
      then
          []
      else
         msgSeqRecurse(count-1) + steps[count-1].MsgSeq()
    }

    // Collapse all the messages in this trunk path
    function MsgSeq() : (out : seq<Message>)
    {
      msgSeqRecurse(|steps|)
    }

    predicate Valid(cache: CacheIfc.Variables) {
      && forall i :: (0 <= i < |steps|) && steps[i].na.ValidCU(cache)
      && steps[0].na.id == 0 // check for root
      && 0 < |MsgSeq()|
      && Last(MsgSeq()).Define?
      && ValidPrefix(cache)
    }

    function Decode() : Value
    {
      var msg := MsgSeqMod.CombineDeltasWithDefine(MsgSeq());
      if msg.None?
      then
        DefaultValue()
      else
        EvaluateMessage(msg.value)
    }
  }

  // QUESTION: Not everything is compacted all at once, should we have this Recipt
  // also have what branches we're compacting
  datatype CompactReceipt = CompactReceipt(path: TrunkPath, newna: NodeAssignment)
  {
    predicate WF() {
      && 0 < |path.steps|
    }

    //
    function Oldna() : NodeAssignment
      requires WF()
    {
      Last(path.steps).na
    }

    predicate Valid(cache: CacheIfc.Variables)
    {
      && WF()
      && path.Valid(cache)
      && Oldna().id == newna.id
    }
  }


  datatype Skolem =
    | QueryStep(trunkPath: TrunkPath)
    | PutStep()
    | FlushStep(flush: FlushRec) // pushdown branch pointers to children
    | DrainMemBufferStep(oldRoot: NodeAssignment, newRoot: NodeAssignment) // Push the memory only stuff into the persistent root of spliten tree as a branctree
    | CompactBranchStep(receipt: CompactReceipt) // Rewrite branches into a new branch.
    | BranchInteralStep(branchSk : BranchTreeMod.Skolem)


  predicate CheckMemtable(v: Variables, v': Variables, key: Key, value: Value)
  {
    && key in v.memBuffer
    && v.memBuffer[key].Define?
    && v.memBuffer[key].value == value
  }

  predicate checkSpinterTree(v: Variables, v': Variables, cache: CacheIfc.Variables, key: Key, value: Value, sk: Skolem)
  {
    && var trunkPath := sk.trunkPath;
    && trunkPath.Valid(cache)
    && trunkPath.k == key
    && trunkPath.Decode() == value
    && v' == v
  }

  predicate Query(v: Variables, v': Variables, cache: CacheIfc.Variables, key: Key, value: Value, sk: Skolem)
  {
    && sk.QueryStep?
    && var inMemBuffer := CheckMemtable(v, v', key, value);
    && var splinterTreePred := checkSpinterTree(v, v', cache, key, value, sk);
    && (|| inMemBuffer
        // We only return the result of the splinterTree if it cannot be found in the membuf
        || !inMemBuffer ==> splinterTreePred
       )
  }

  predicate Put(v: Variables, v': Variables, key: Key, value: Value, sk: Skolem)
  {
    && sk.PutStep?
    && var newMessage := MakeValueMessage(value);
    && v' == v.(memBuffer := v.memBuffer[key := newMessage], nextSeq := v.nextSeq + 1)
  }

  predicate PutMany(v: Variables, v': Variables, puts: MsgSeq) {
    &&  v' == v.(memBuffer := puts.ApplyToKeyMap(v.memBuffer), nextSeq := v.nextSeq + puts.Len())
  }

  datatype FlushRec = FlushRec(
    trunkPath: TrunkPath,
    newParent: NodeAssignment,
    newChild: NodeAssignment)
  {
    predicate WF() {
      2<=|trunkPath.steps|
    }
    predicate Valid(cache: CacheIfc.Variables) {
      && WF()
      && trunkPath.ValidPrefix(cache)
    }
    function ParentStep() : TrunkStep
      requires WF()
      { trunkPath.steps[|trunkPath.steps|-2] }
    function ChildStep() : TrunkStep
      requires WF()
      { trunkPath.steps[|trunkPath.steps|-1] }
    function ParentNode() : TrunkNode
      requires WF()
      { ParentStep().na.node }
    function ChildNode() : TrunkNode
      requires WF()
      { ChildStep().na.node }
  }

  // TODO: We need make sure this flush op is flushing entire prefix of local trunk versions
  predicate FlushesNodes(oldParent: TrunkNode, oldChild: TrunkNode, newParent: TrunkNode, newChild: TrunkNode)
    requires oldParent.WF()
    requires newParent.WF()
    requires oldChild.WF()
    requires newChild.WF()
  {
    // ensure that they're still children of the parent
    && newChild in newParent.children
    && oldChild in oldParent.children
    && newParent.branches == oldParent.branches
    && newParent.children == oldParent.children
    && newChild.children == oldChild.children
    && newChild.activeBranches == oldChild.activeBranches // Our flush is only one layer, so the activeBranches here shouldn't change
    // check that newChild got a branch from the oldParent
    && var oldChildId :| (0 <= oldChildId < |oldParent.children|) && oldParent.children[oldChildId] == oldChild;
    && var newChildId :| (0 <= newChildId < |newParent.children|) && newParent.children[newChildId] == newChild;
    && oldChildId == newChildId
    // for now we're flushing all current branches??
    && forall i :: (&& oldParent.activeBranches[oldChildId] <= i < |oldParent.branches|
                    && oldParent.branches[i] in newChild.branches)
    && newParent.activeBranches[newChildId] == |newParent.branches|

  }

  predicate CUIsAllocatable(cu: CU)
  {
    && true // TODO cu unallocated across all live views
  }

  // Internal operation; noop -- atomic
  predicate Flush(v: Variables, v': Variables, cache: CacheIfc.Variables, cacheOps: CacheIfc.Ops, sk: Skolem)
  {
    && sk.FlushStep?
    && var flush := sk.flush;
    && flush.Valid(cache)
    // TODO keep the parent's trunkId, but move the child, so that other nodes' outbound links
    // to existing child don't change.
    && FlushesNodes(flush.ParentNode(), flush.ChildNode(), flush.newParent.node, flush.newChild.node)
    && flush.newParent.id == flush.ParentStep().na.id  // parent keeps its id
    && true // UnusedId(flush.newChild.id) child gets id unallocated in eph ind tbl
    && CUIsAllocatable(flush.newParent.cu)
    && CUIsAllocatable(flush.newChild.cu)
    && cacheOps == [
      CacheIfc.Write(flush.newParent.cu, marshalTrunkNode(flush.newParent.node)),
      CacheIfc.Write(flush.newChild.cu, marshalTrunkNode(flush.newChild.node))
      ]
    && v' == v.(indTbl := v.indTbl
      [flush.ParentStep().na.id := flush.newParent.cu]
      [flush.newChild.id := flush.newChild.cu])  // TODO breaks other dag neighbors
  }

  // the newNode must contain all the messages in the oldNode and memBuffer combined.
  // merge the two memBuffer has the most uptodate updates
  // QUESTION : Why do we need this??
  predicate MergeBuffer(oldNode: TrunkNode, memBuffer: map<Key, Message>, newNode: TrunkNode)
  {
    && MapUnionPreferA(memBuffer, oldNode.AllMessages()) == newNode.AllMessages()
  }

  // Internal
  // drain mem buffer into a B+tree in the root trunk node
  predicate DrainMemBuffer(v: Variables, v': Variables, cache: CacheIfc.Variables, cacheOps: CacheIfc.Ops, sk:Skolem)
  {
    && sk.DrainMemBufferStep?
    && var oldRoot := sk.oldRoot;
    && var newRoot := sk.newRoot;
    && oldRoot.id == RootId()
    && oldRoot.Valid(v, cache)
    && newRoot.id == RootId()
    // when we're done, newRoot.Valid(v', cache')

    && CUIsAllocatable(newRoot.cu)
    && MergeBuffer(oldRoot.node, v.memBuffer, newRoot.node)
    && cacheOps == [ CacheIfc.Write(newRoot.cu, marshalTrunkNode(newRoot.node)) ]
    && v' == v.(
      indTbl := v.indTbl[RootId() := newRoot.cu],
      memBuffer := map[]
      )
  }

  // QUESTION: What is this supposed to do???
  predicate EquivalentNodes(a: TrunkNode, b: TrunkNode) {
    true // TODO
  }

  // Internal operation; noop
  // Rearrange mem buffers in some node
  predicate CompactBranch(v: Variables, v': Variables, cache: CacheIfc.Variables, cacheOps: CacheIfc.Ops, sk: Skolem)
  {
    && sk.CompactBranchStep?
    && var r := sk.receipt;
    && r.Valid(cache)
    && CUIsAllocatable(r.newna.cu)
    && EquivalentNodes(r.Oldna().node, r.newna.node)  // Buffer replacements
      // TODO need to establish replacement B+tree is correct
    // check that we update the trunknode we're compacting in the cache
    && cacheOps == [ CacheIfc.Write(r.newna.cu, marshalTrunkNode(r.newna.node)) ]
    && v' == v.(indTbl := v.indTbl[r.newna.id := r.newna.cu])
  }

  // TODO: Sowmya check when this freeze happens and why
  predicate Freeze(v: Variables, v': Variables)
  {
    && v.frozen.Idle?
    && v.memBuffer == map[]  // someday we'd like to avoid clogging the memtable during freeze, but...
    && v' == v.(frozen := Frozen(v.indTbl,  v.nextSeq))
  }

  predicate KnowFrozenIsClean(v: Variables, sb: Superblock, cache: CacheIfc.Variables)
  {
    true // TODO
  }

  predicate Internal(v: Variables, v': Variables, cache: CacheIfc.Variables, cacheOps: CacheIfc.Ops, sk: Skolem)
  {
    || Flush(v, v', cache, cacheOps, sk)
    || DrainMemBuffer(v, v', cache, cacheOps, sk)
    // Sowmya : BranchTrees are immutable, so I don't think this step is necessary?
    //|| BranchInternal(v, v', cache, cacheOps, sk) // memBuffer doesn't change
    || CompactBranch(v, v', cache, cacheOps, sk) // trunk update
  }

  predicate CommitStart(v: Variables, v': Variables, cache: CacheIfc.Variables, sb: Superblock, newBoundaryLSN: LSN)
  {
    && v.frozen.Frozen?
    && KnowFrozenIsClean(v, sb, cache)
    && sb.endSeq == v.frozen.endSeq
    && v' == v
  }

  predicate CommitComplete(v: Variables, v': Variables, cache: CacheIfc.Variables, sb: Superblock)
  {
    // TODO need to update the persistent table to keep our allocation set correct
    && v' == v.(frozen := Idle)
  }

/*
  predicate ReachableTrunk(sb: Superblock, trunkRoot: CU)
  {
    && true // TODO -- lookup-y definition
  }

  predicate ReachableBranch(cache: CacheIfc.Variables, sb: Superblock, branchRoot: CU)
  {
    // NB: no indirection from trunks to branches -- but there is refcounting here. Use multiset representation for IReads, I guess.
    exists trunkCU, trunkNode, branchIdx ::
      && ReachableTrunk(sb, trunkCU)
      && var unparsedPage := CacheIfc.ReadValue(cache, trunkCU);
      && unparsedPage.Some?
      && var trunkNode := parseTrunkNode(unparsedPage.value);
      && trunkNode.Some?
      // TODO trunk nodes need some guts
      //&& trunkNode.value.branches[branchIdx] == branchRoot
  }

  predicate BranchMember(sb: Superblock, branchRoot: CU, block: CU)
  {
    && true // TODO -- this defn belongs inside branch module
  }

  predicate ReachableBlock(cache: CacheIfc.Variables, sb: Superblock, cu: CU)
  {
    || ReachableTrunk(cache, trunkCu)
    || (exists branch ::
      && ReachableBranch(cache, sb, trunkCu)
      && BranchMember(branchRoot, cu))
  }
*/

  // And then IReads <= ReachableBlocks == alloc.
  // We can prove this because anything in IReads justifies ReachableTrunk (and maybe BranchMember).

  function Alloc(v: Variables, cache: CacheIfc.Variables, sb: Superblock) : set<CU>
  {
    {}  // TODO: this will make proving framing really hard.
  }
}
