// Copyright 2018-2021 VMware, Inc., Microsoft Inc., Carnegie Mellon University, ETH Zurich, and University of Washington
// SPDX-License-Identifier: BSD-2-Clause


include "FSTypes.s.dfy"
include "../../lib/Lang/System/SeqComparison.s.dfy"

/*
 * This file system doesn't specify any permission checking or path cleanup: relying on shim/vfs to do so.
 * It defines an in memory filesystem, has no knowledge of device and persistence.
*/

module FileSystem {
  import opened FSTypes
  import opened PathSpec
  import opened Options
  import SeqComparison

  type MetaView = imap<int, MetaData>
  type DataView = imap<int, Data> 

  datatype FileSys = FileSys(path_map: PathMap, meta_map: MetaView, data_map: DataView)

  predicate WF(fs: FileSys)
  {
    && PathComplete(fs.path_map)
    && (forall id :: id in fs.meta_map && id in fs.data_map)
  }

  predicate Init(fs: FileSys)
  {
    && fs.path_map == InitPathMap()
    && fs.meta_map == (imap id :: if id == RootId then InitRootMetaData() else EmptyMetaData)
    && fs.data_map == (imap id :: EmptyData())
  }
  /// Inv conditions

  function AliasPaths(fs: FileSys, id: int) : (aliases: iset<Path>)
  requires WF(fs)
  ensures forall path | path !in aliases :: fs.path_map[path] != id
  {
    iset path | fs.path_map[path] == id
  }

  predicate NoAlias(fs: FileSys, id: int, path: Path)
  requires WF(fs)
  requires fs.path_map[path] == id
  {
    && AliasPaths(fs, id) == iset{path}
  }

  predicate DirHasNoAlias(fs: FileSys, path: Path)
  requires WF(fs)
  requires ValidPath(fs, path)
  {
    var id := fs.path_map[path];
    var m := fs.meta_map[id];
    && (m.ftype.Directory? ==> NoAlias(fs, id, path))
  }

  predicate ParentDirIsDir(fs: FileSys, path: Path)
  requires WF(fs)
  {
    var parent_dir := GetParentDir(path);
    var parent_id := fs.path_map[parent_dir];
    && ValidPath(fs, parent_dir)
    && fs.meta_map[parent_id].ftype.Directory?
  }

  predicate ValidPath(fs: FileSys, path: Path)
  requires WF(fs)
  {
    && fs.path_map[path] != DefaultId
    && fs.meta_map[fs.path_map[path]].MetaData?
  }

  predicate ValidNewPath(fs: FileSys, path: Path)
  requires WF(fs)
  {
    && ParentDirIsDir(fs, path)
    && IsDirEntry(GetParentDir(path), path)
    && fs.path_map[path] == DefaultId
  }

  predicate ValidNewId(fs: FileSys, id: int)
  requires WF(fs)
  {
    && id != DefaultId
    && AliasPaths(fs, id) == iset{}
  }

  /// FileSys Ops

  predicate GetAttr(fs: FileSys, fs':FileSys, path: Path, attr: MetaData)
  {
    && WF(fs)
    && ValidPath(fs, path)
    && fs' == fs
    && attr == fs.meta_map[fs.path_map[path]]
  }

  predicate ReadLink(fs: FileSys, fs':FileSys, path: Path, link_path: Path)
  {
    && WF(fs)
    && ValidPath(fs, path)
    && fs' == fs
    && fs.meta_map[fs.path_map[path]].ftype.SymLink?
    && link_path == fs.meta_map[fs.path_map[path]].ftype.source
  }

  predicate Create(fs: FileSys, fs':FileSys, path: Path, id: int, m: MetaData)
  {
    && WF(fs)
    && WF(fs')
    && ValidNewPath(fs, path)
    && ValidNewMetaData(m, path)
    && ValidNewId(fs, id)
    // Entry Not Present
    && fs.meta_map[id].EmptyMetaData?
    && fs.data_map[id] == EmptyData()
    // Updated maps
    && fs'.path_map == fs.path_map[path := id]
    && fs'.meta_map == fs.meta_map[id := m]
    && fs'.data_map == fs.data_map
  }

  function MetaDataUpdateCTime(m: MetaData, ctime: Time): MetaData
  requires m.MetaData?
  {
    MetaData(m.ftype, m.perm, m.uid, m.gid, m.atime, m.mtime, ctime)
  }

  function MetaDataDelete(fs: FileSys, path: Path, ctime: Time): MetaData
  requires WF(fs)
  requires ValidPath(fs, path)
  {
    var id := fs.path_map[path];

    if NoAlias(fs, id, path)
    then EmptyMetaData
    else MetaDataUpdateCTime(fs.meta_map[id], ctime)
  }

  function DataDelete(fs: FileSys, path: Path): Data
  requires WF(fs)
  requires ValidPath(fs, path)
  {
    var id := fs.path_map[path];
    if NoAlias(fs, id, path)
    then EmptyData()
    else fs.data_map[id]
  }

  predicate Delete(fs: FileSys, fs':FileSys, path: Path, ctime: Time)
  {
    && WF(fs)
    && WF(fs')
    && path != RootDir
    && ValidPath(fs, path)
    && var id := fs.path_map[path];
    && (fs.meta_map[id].ftype.Directory? ==> IsEmptyDir(fs.path_map, path))
    // maps after delete
    && fs'.path_map == fs.path_map[path := DefaultId]
    && fs'.meta_map == fs.meta_map[id := MetaDataDelete(fs, path, ctime)]
    && fs'.data_map == fs.data_map[id := DataDelete(fs, path)]
  }

  predicate SymLink(fs: FileSys, fs':FileSys, source: Path, dest: Path, id: int, m: MetaData)
  {
    && WF(fs)
    && WF(fs')
    && ValidNewPath(fs, dest) // source doesn't need to be valid
    && ValidNewMetaData(m, dest)
    && m.ftype == FileType.SymLink(source)
    && ValidNewId(fs, id)
    && fs.meta_map[id] == EmptyMetaData
    && fs.data_map[id] == EmptyData()
    // updated maps
    && fs'.path_map == fs.path_map[dest := id]
    && fs'.meta_map == fs.meta_map[id := m]
    && fs'.data_map == fs.data_map
  }

  function PathMapRenameDir(fs: FileSys, src: Path, dst: Path): PathMap
  requires WF(fs)
  {
    imap path :: 
      // remove source paths
      if path == src || InDir(src, path) then DefaultId
      // redirect renamed paths to point to the same ids as source
      else if path == dst || InDir(dst, path) then fs.path_map[src + path[|dst|..]]
      // everything else remains the same
      else fs.path_map[path]
  }

  predicate RenameDir(fs: FileSys, fs':FileSys, src: Path, dst: Path, ctime: Time)
  requires WF(fs)
  requires WF(fs')
  requires ValidPath(fs, src)
  requires ValidPath(fs, dst) || ValidNewPath(fs, dst)
  {
    var src_id := fs.path_map[src];
    var dst_id := fs.path_map[dst];
    var src_m := fs.meta_map[src_id];
    var src_m' := MetaDataUpdateCTime(src_m, ctime);
    && src_m.ftype.Directory?
    && (ValidPath(fs, dst) ==>
      && fs.meta_map[fs.path_map[dst]].ftype.Directory?
      && IsEmptyDir(fs.path_map, dst))
    // updated maps
    && fs'.path_map == PathMapRenameDir(fs, src, dst)
    && fs'.meta_map == (
      if ValidPath(fs, dst)
      then fs.meta_map[src_id := src_m'][dst_id := EmptyMetaData]
      else fs.meta_map[src_id := src_m'])
    && fs'.data_map == fs.data_map
  }

  predicate RenameNonDir(fs: FileSys, fs':FileSys, src: Path, dst: Path, ctime: Time)
  requires WF(fs)
  requires WF(fs')
  requires ValidPath(fs, src)
  requires ValidPath(fs, dst) || ValidNewPath(fs, dst)
  {
    var src_id := fs.path_map[src];
    var dst_id := fs.path_map[dst];
    var src_m := fs.meta_map[src_id];
    var src_m' := MetaDataUpdateCTime(src_m, ctime);
    && !src_m.ftype.Directory? // file, symlink, dev file, fifo, socket
    // updated maps
    && fs'.path_map == fs.path_map[dst := src_id][src := DefaultId]
    && (ValidPath(fs, dst) ==> 
      && src_id != dst_id
      && !fs.meta_map[dst_id].ftype.Directory?
      && fs'.meta_map == fs.meta_map[src_id := src_m'][dst_id := MetaDataDelete(fs, dst, ctime)]
      && fs'.data_map == fs.data_map[dst_id := DataDelete(fs, dst)])
    && (!ValidPath(fs, dst) ==>
      && fs'.meta_map == fs.meta_map[src_id := src_m']
      && fs'.data_map == fs.data_map)
  }

  // rename is a map because we allow directory
  predicate Rename(fs: FileSys, fs':FileSys, src: Path, dst: Path, ctime: Time)
  {
    && WF(fs)
    && WF(fs')
    && ValidPath(fs, src)
    && !InDir(dst, src)
    && (ValidPath(fs, dst) || ValidNewPath(fs, dst))
    && var src_m := fs.meta_map[fs.path_map[src]];
    && (src_m.ftype.Directory? ==> RenameDir(fs, fs', src, dst, ctime))
    && (!src_m.ftype.Directory? ==> RenameNonDir(fs, fs', src, dst, ctime))
  }

  predicate Link(fs: FileSys, fs':FileSys, source: Path, dest: Path, ctime: Time)
  {
    && WF(fs)
    && WF(fs')
    && ValidPath(fs, source)  // NOTE: won't work for hardlink other filesystem files
    && ValidNewPath(fs, dest)
    && var id := fs.path_map[source];
    && var m := fs.meta_map[id];
    && !m.ftype.Directory?  // disallow directory hardlinks
    // updated maps
    && fs'.path_map == fs.path_map[dest := id]
    && fs'.meta_map == fs.meta_map[id := MetaDataUpdateCTime(m, ctime)]
    && fs'.data_map == fs.data_map
  }

  function MetaDataChangeAttr(m: MetaData, perm: int, uid:int, gid: int, ctime: Time): MetaData
  requires m.MetaData?
  {
    MetaData(m.ftype, perm, uid, gid, m.atime, m.mtime, ctime)
  }

  // chown + chmod
  predicate ChangeAttr(fs: FileSys, fs':FileSys, path: Path, perm: int, uid: int, gid: int, ctime: Time)
  {
    && WF(fs)
    && WF(fs')
    && ValidPath(fs, path)
    && var id := fs.path_map[path];
    && fs'.path_map == fs.path_map
    && fs'.meta_map == fs.meta_map[id := MetaDataChangeAttr(fs.meta_map[id], perm, uid, gid, ctime)]
    && fs'.data_map == fs.data_map
  }

  function MetaDataUpdateTime(m: MetaData, atime: Time, mtime: Time, ctime: Time): MetaData
  requires m.MetaData?
  {
    MetaData(m.ftype, m.perm, m.uid, m.gid, atime, mtime, ctime)
  }

  function ZeroData(size: int) : (d: Data)
  requires size >= 0
  ensures size == |d|
  ensures forall i | 0 <= i < |d| :: d[i] == 0
  {
    if size == 0 then [] else ZeroData(size-1) + [0]
  }

  function DataTruncate(d: Data, size: int): (d': Data)
  requires 0 <= size
  ensures |d'| == size
  {
    if |d| >= size then d[..size] else d + ZeroData(size-|d|)
  }

  predicate Truncate(fs: FileSys, fs':FileSys, path: Path, size: int, time: Time)
  {
    && WF(fs)
    && WF(fs')
    && 0 <= size
    && ValidPath(fs, path)
    && var id := fs.path_map[path];
    && var m := fs.meta_map[id];
    && m.ftype.File?
    && size != |fs.data_map[id]|
    // updated maps
    && fs'.path_map == fs.path_map
    && fs'.meta_map == fs.meta_map[id := MetaDataUpdateTime(m, m.atime, time, time)]
    && fs'.data_map == fs.data_map[id := DataTruncate(fs.data_map[id], size)]
  }

  predicate Read(fs: FileSys, fs':FileSys, path: Path, offset: int, size: int, data: Data)
  {
    && WF(fs)
    && fs' == fs
    && ValidPath(fs, path)
    && var id := fs.path_map[path];
    && fs.meta_map[id].ftype.File?
    && 0 <= offset <= offset+size <= |fs.data_map[id]|
    && data == fs.data_map[id][offset..offset+size]
  }

  function DataWrite(d: Data, data: Data, offset: int, size: int): (d': Data)
  requires 0 <= offset <= |d|
  requires size == |data|
  ensures offset <= offset+size <= |d'|
  ensures d'[offset..offset+size] == data
  {
    if offset+size > |d| then d[..offset] + data else d[..offset] + data + d[offset+size..]
  }

  predicate Write(fs: FileSys, fs':FileSys, path: Path, offset: int, size: int, data: Data, time: Time)
  {
    && WF(fs)
    && WF(fs')
    && ValidPath(fs, path)
    && |data| == size
    && var id := fs.path_map[path];
    && var m := fs.meta_map[id];
    && m.ftype.File?
    && 0 <= offset <= |fs.data_map[id]|
    // updated maps
    && fs'.path_map == fs.path_map
    && fs'.meta_map == fs.meta_map[id := MetaDataUpdateTime(m, time, time, time)]
    && fs'.data_map == fs.data_map[id := DataWrite(fs.data_map[id], data, offset, size)]
  }

  predicate UpdateTime(fs: FileSys, fs':FileSys, path: Path, atime: Time, mtime: Time, ctime: Time)
  {
    && WF(fs)
    && WF(fs')
    && ValidPath(fs, path)
    && var id := fs.path_map[path];
    && fs'.path_map == fs.path_map
    && fs'.meta_map == fs.meta_map[id := MetaDataUpdateTime(fs.meta_map[id], atime, mtime, ctime)]
    && fs'.data_map == fs.data_map
  }

  predicate ValidDirEntry(fs: FileSys, de: DirEntry)
  requires WF(fs)
  {
    && ValidPath(fs, de.path) // valid path
    && de.id == fs.path_map[de.path]
    && de.ftype == fs.meta_map[de.id].ftype
  }

  predicate ReadDir(fs: FileSys, fs':FileSys, dir: Path, start: Option<Path>, results: seq<DirEntry>, done: bool)
  {
    && WF(fs)
    && fs' == fs
    && ValidPath(fs, dir)
    && fs.meta_map[fs.path_map[dir]].ftype.Directory?
    && (start.Some? ==> InDir(dir, start.value))
    // results consistent with filesys content
    && (forall i | 0 <= i < |results| :: ValidDirEntry(fs, results[i]))
    // results actually belong to this directory
    && (forall i | 0 <= i < |results| :: IsDirEntry(dir, results[i].path))
    // results are strictly sorted
    && (forall i, j | 0 <= i < j < |results| :: SeqComparison.lt(results[i].path, results[j].path))
    // results don't skip over any valid entry
    && (forall path |
        && IsDirEntry(dir, path)
        && ValidPath(fs, path)
        && (start.Some? ==> SeqComparison.lte(path, start.value))
        && (!done && |results| > 0 ==> SeqComparison.lt(results[|results|-1].path, path))
        :: (exists i :: 0 <= i < |results| && results[i].path == path))
  }

  predicate Stutter(fs: FileSys, fs': FileSys)
  {
    && WF(fs)
    && fs' == fs
  }

  datatype Step =
    | GetAttrStep(path: Path, attr: MetaData)
    | ReadLinkStep(path: Path, link_path: Path)
    | CreateStep(path: Path, id: int, m: MetaData) // mknod and mkdir
    | DeleteStep(path: Path, ctime: Time) // unlink and rmdir
    | SymLinkStep(source: Path, dest: Path, id: int, m: MetaData)
    | RenameStep(source: Path, dest: Path, ctime: Time)
    | LinkStep(source: Path, dest: Path, ctime: Time)
    | ChangeAttrStep(path: Path, perm: int, uid: int, gid: int, ctime: Time) // chmod + chown
    | TruncateStep(path: Path, size: int, time: Time)
    | ReadStep(path: Path, offset: int, size: int, data: Data)
    | WriteStep(path: Path, offset: int, size: int, data: Data, time: Time)
    | UpdateTimeStep(path: Path, atime: Time, mtime: Time, ctime: Time) 
    | ReadDirStep(dir: Path, start: Option<Path>, results: seq<DirEntry>, done: bool)
    | StutterStep

  predicate NextStep(fs: FileSys, fs': FileSys, step:Step)
  {
    match step {
      case GetAttrStep(path, attr) => GetAttr(fs, fs', path, attr)
      case ReadLinkStep(path, link_path) => ReadLink(fs, fs', path, link_path)
      case CreateStep(path, id, m) => Create(fs, fs', path, id, m)
      case DeleteStep(path, ctime) => Delete(fs, fs', path, ctime)
      case SymLinkStep(source, dest, id, m) => SymLink(fs, fs', source, dest, id, m)
      case RenameStep(source, dest, ctime) => Rename(fs, fs', source, dest, ctime)
      case LinkStep(source, dest, ctime) => Link(fs, fs', source, dest, ctime)
      case ChangeAttrStep(path, perm, uid, gid, ctime) => ChangeAttr(fs, fs', path, perm, uid, gid, ctime)
      case TruncateStep(path, size, time) => Truncate(fs, fs', path, size, time)
      case ReadStep(path, offset, size, data) => Read(fs, fs', path, offset, size, data)
      case WriteStep(path, offset, size, data, time) => Write(fs, fs', path, offset, size, data, time)
      case UpdateTimeStep(path, atime, mtime, ctime) => UpdateTime(fs, fs', path, atime, mtime, ctime)
      case ReadDirStep(dir, start, results, done) => ReadDir(fs, fs', dir, start, results, done)
      case StutterStep() => Stutter(fs, fs')
    }
  }

  predicate Next(fs: FileSys, fs': FileSys)
  {
    exists step :: NextStep(fs, fs', step)
  }

  predicate Inv(fs: FileSys)
  {
    && WF(fs)
    // DefaultId is never occupied
    && fs.meta_map[DefaultId].EmptyMetaData?
    && fs.data_map[DefaultId] == EmptyData()
    // Path map internal invariant :: all valid paths must be greater than 0
    && (forall path | ValidPath(fs, path) :: |path| > 0) // all valid path must 
    // Metadata map internal consistency: nlink consitency and directory has no hardlinks
    && (forall path | ValidPath(fs, path) :: DirHasNoAlias(fs, path))
    // Path and meta map consistency: directory structure is connected
    && (forall path | ValidPath(fs, path) && path != RootDir :: ParentDirIsDir(fs, path))
  }

  lemma InitImpliesInv(fs: FileSys)
  requires Init(fs)
  ensures Inv(fs)
  {
  }

  // TODO: add ui op
  lemma NextPreservesInv(fs: FileSys, fs': FileSys)
  requires Inv(fs)
  requires Next(fs, fs')
  ensures Inv(fs')
  {
    var step :| NextStep(fs, fs', step);
    NextStepPreservesInv(fs, fs', step);
  }

  lemma NextStepPreservesInv(fs: FileSys, fs': FileSys, step: Step)
  requires Inv(fs)
  requires NextStep(fs, fs', step)
  ensures Inv(fs')
  {
    match step {
      case DeleteStep(path, ctime) => DeletePreservesInv(fs, fs', path, ctime);
      case RenameStep(source, dest, ctime) => RenamePreservesInv(fs, fs', source, dest, ctime);
      case LinkStep(source, dest, ctime) => LinkPreservesInv(fs, fs', source, dest, ctime); 
      case _ => {
        if step.CreateStep? || step.SymLinkStep? || step.ChangeAttrStep? 
        || step.TruncateStep? || step.WriteStep? || step.UpdateTimeStep? {
          SimpleStepPreservesInv(fs, fs', step);
        }
      }
    }
  }

  /// Invariant proofs

  lemma SameAliases(fs: FileSys, fs': FileSys, changedPaths: iset<Path>, changedIds: iset<int>)
  requires Inv(fs)
  requires WF(fs')
  requires forall p | p in changedPaths :: fs.path_map[p] in changedIds || fs.path_map[p] == DefaultId
  requires forall p | p in changedPaths :: fs'.path_map[p] in changedIds || fs'.path_map[p] == DefaultId
  requires forall p | p !in changedPaths :: fs'.path_map[p] == fs.path_map[p]
  requires forall p | p !in changedPaths :: fs'.path_map[p] !in changedIds
  ensures forall p | ValidPath(fs, p) && ValidPath(fs', p) && p !in changedPaths ::
    AliasPaths(fs, fs.path_map[p]) == AliasPaths(fs', fs'.path_map[p])
  {
  }

  lemma DeletePreservesInv(fs: FileSys, fs': FileSys, path: Path, ctime: Time)
  requires Inv(fs)
  requires Delete(fs, fs', path, ctime)
  ensures Inv(fs')
  {
    forall p | ValidPath(fs', p)
    ensures DirHasNoAlias(fs', p)
    ensures p != RootDir ==> ParentDirIsDir(fs', p)
    {
      assert DirHasNoAlias(fs, p); // observe
      assert p != RootDir ==> ParentDirIsDir(fs, p); // observe
  
      var id := fs.path_map[path];
      if fs'.path_map[p] != id {
        SameAliases(fs, fs', AliasPaths(fs, id), iset{id});
      }
    }

    assert Inv(fs');
  }

  lemma RenameNonDirPreservesInv(fs: FileSys, fs': FileSys, src: Path, dst: Path, ctime: Time)
  requires Inv(fs)
  requires Rename(fs, fs', src, dst, ctime)
  requires RenameNonDir(fs, fs', src, dst, ctime)
  ensures Inv(fs')
  {
    assert fs'.meta_map[DefaultId].EmptyMetaData?; // observe

    forall p | ValidPath(fs', p)
    ensures DirHasNoAlias(fs', p)
    ensures p != RootDir ==> ParentDirIsDir(fs', p)
    {
      var src_id := fs.path_map[src];
      var dst_id := fs.path_map[dst];

      if fs'.path_map[p] != src_id && fs'.path_map[p] != dst_id {
        var changedIds := if ValidPath(fs, dst) then iset{src_id, dst_id} else iset{src_id};
        var changedPaths := iset path | fs.path_map[path] in changedIds || fs'.path_map[path] in changedIds;

        SameAliases(fs, fs', changedPaths, changedIds);
        assert DirHasNoAlias(fs, p);
      }
      assert DirHasNoAlias(fs', p);

      if p != RootDir {
        assert ParentDirIsDir(fs, p); // observe
        assert ParentDirIsDir(fs', p);
      }
    }
    assert Inv(fs');
  }

  lemma RenameDirPreservesInv(fs: FileSys, fs': FileSys, src: Path, dst: Path, ctime: Time)
  requires Inv(fs)
  requires Rename(fs, fs', src, dst, ctime)
  requires RenameDir(fs, fs', src, dst, ctime)
  ensures Inv(fs')
  {
    // var paths := (iset path | path == src || InDir(src, path) || path == dst || InDir(dst, path) :: path);
    // var changedIds := (iset path | path in paths && fs.path_map[path] != DefaultId :: fs.path_map[path]);
        // + (iset path | path in paths && fs'.path_map[path] != DefaultId :: fs'.path_map[path]);
    // var changedPaths := (iset path | fs.path_map[path] in changedIds || fs'.path_map[path] in changedIds);
    // var changedPaths := (iset path | fs.path_map[path] in changedIds || fs'.path_map[path] in changedIds);

    // requires forall p | p in changedPaths :: fs.path_map[p] in changedIds || fs.path_map[p] == DefaultId  
    // SameAliases(fs, fs', changedPaths, changedIds);
    // forall p | ValidPath(fs', p)
    // ensures DirHasNoAlias(fs', p)
    // ensures p != RootDir ==> ParentDirIsDir(fs', p)
    // {
    //   var paths := (iset path | path == src || InDir(src, path) || path == dst || InDir(dst, path) :: path);
    //   var changedIds := (iset path | path in paths && fs.path_map[path] != DefaultId :: fs.path_map[path]);
    //     // + (iset path | path in paths && fs'.path_map[path] != DefaultId :: fs'.path_map[path]);
    //   var changedPaths := (iset path | fs.path_map[path] in changedIds || fs'.path_map[path] in changedIds);
    //   SameAliases(fs, fs', changedPaths, changedIds);

    //   if p in changedPaths {
    //     if p == dst || InDir(dst, p) {

    //     } else {
    //       assert ValidPath(fs, p);
    //       assert DirHasNoAlias(fs, p);

    //       // these are aliased therefore not a directory
    //       var id := fs.path_map[p];
    //       var m := fs.meta_map[id];

    //       if m.ftype.Directory? {
    //         assert NoAlias(fs, id, p);
    //         assert id in changedIds;
    //         assert id != DefaultId;

    //         // assert p in paths;

    //         // assert p in paths;

    //       }
    //     }

    //     // rename should get rid of 
    //     // assert p != src;
    //     // assert !InDir(src, p);

    //     // assert p == dst || InDir(dst, path) ||


    //     // assert DirHasNoAlias(fs', p);

    //     assume DirHasNoAlias(fs', p);
    //   } else {
    //     assert ValidPath(fs, p);
    //     assert DirHasNoAlias(fs, p);
    //     assert DirHasNoAlias(fs', p);
    //   }

    //   assume p != RootDir ==> ParentDirIsDir(fs', p);
    // }
    assume false;
    // assert Inv(fs');
  }

  lemma RenamePreservesInv(fs: FileSys, fs': FileSys, source: Path, dest: Path, ctime: Time)
  requires Inv(fs)
  requires Rename(fs, fs', source, dest, ctime)
  ensures Inv(fs')
  {
    var m := fs.meta_map[fs.path_map[source]];
    if m.ftype.Directory? {
      RenameDirPreservesInv(fs, fs', source, dest, ctime);
    } else {
      RenameNonDirPreservesInv(fs, fs', source, dest, ctime);
    }
  }

  lemma LinkPreservesInv(fs: FileSys, fs': FileSys, source: Path, dest: Path, ctime: Time)
  requires Inv(fs)
  requires Link(fs, fs', source, dest, ctime)
  ensures Inv(fs')
  {
    forall p | ValidPath(fs', p)
    ensures DirHasNoAlias(fs', p)
    ensures p != RootDir ==> ParentDirIsDir(fs', p)
    {
      assert p != dest ==> DirHasNoAlias(fs, p); // observe
      assert p != RootDir ==> ParentDirIsDir(fs, p); // observe

      var id := fs.path_map[source];
      if fs'.path_map[p] != id {
        SameAliases(fs, fs', AliasPaths(fs', id), iset{id});
      }
    }

    assert Inv(fs');
  }

  lemma SimpleStepPreservesInv(fs: FileSys, fs': FileSys, step: Step)
  requires Inv(fs)
  requires NextStep(fs, fs', step)
  requires step.CreateStep? || step.SymLinkStep? || step.ChangeAttrStep?
        || step.TruncateStep? || step.WriteStep? || step.UpdateTimeStep?
  ensures Inv(fs')
  {
    var path := if step.SymLinkStep? then step.dest else step.path;

    forall p | ValidPath(fs', p)
    ensures DirHasNoAlias(fs', p)
    ensures p != RootDir ==> ParentDirIsDir(fs', p)
    {
      if p != path {
        assert ValidPath(fs, p); // observe
        assert DirHasNoAlias(fs, p); // observe

        if step.SymLinkStep? || step.CreateStep? {
          SameAliases(fs, fs', iset{path}, iset{fs'.path_map[path]});
        }
      }
    }

  //   assert WF(fs');
  //   assert fs'.meta_map[DefaultId].EmptyMetaData?;
  //   assert fs'.data_map[DefaultId] == EmptyData();

  //   assert (forall p | ValidPath(fs', p) :: |p| > 0);
  //   assert (forall p | ValidPath(fs', p) :: DirHasNoAlias(fs', p));
  //   assert (forall p | ValidPath(fs', p) && p != RootDir :: ParentDirIsDir(fs', p));

    assert Inv(fs');
  }
}
