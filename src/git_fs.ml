(************************************vim: set tw=0 sw=2 ts=2 et :**********)
(*  Copyright (C) 2012 G2P                                                *)
(*                                                                        *)
(*  This file is part of git-fs.                                          *)
(*                                                                        *)
(*  git-fs is free software: you can redistribute it and/or modify        *)
(*  it under the terms of the GNU General Public License as published by  *)
(*  the Free Software Foundation, either version 2 of the License, or     *)
(*  (at your option) any later version.                                   *)
(*                                                                        *)
(*  git-fs is distributed in the hope that it will be useful,             *)
(*  but WITHOUT ANY WARRANTY; without even the implied warranty of        *)
(*  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the         *)
(*  GNU General Public License for more details.                          *)
(*                                                                        *)
(*  You should have received a copy of the GNU General Public License     *)
(*  along with git-fs.  If not, see <http://www.gnu.org/licenses/>.       *)
(**************************************************************************)

(* Cached refs expiry, in seconds *)
let ref_expiration_secs = 10.

(* Shorthand *)
module UL = Unix.LargeFile

(* a |> b |> c is equivalent to c (b a).
  I haven't found Haskell's ($) operator yet,
  probably because it is right-associative.
  *)
let (|>) = BatPervasives.(|>)

module Subprocess = struct
  (* http://caml.inria.fr/cgi-bin/viewcvs.cgi/ocaml/trunk/otherlibs/unix/unix.ml?view=markup *)

  (* Consider getting a patch that adds an alternative open_proc implementation.
   * Could use labels, pick execve / execvp / execvpe /execv,
   * even take a
   *   type ShellCommand of string | ExecCommand of string array
   *)

  open Unix

  type popen_process =
    | Process of in_channel * out_channel
    | Process_in of in_channel
    | Process_out of out_channel
    | Process_full of in_channel * out_channel * in_channel

  let popen_processes = (Hashtbl.create 7 : (popen_process, int) Hashtbl.t)

  let open_proc cmd proc input output toclose =
    let _ = List.iter set_close_on_exec toclose in
    match fork () with
    | 0 ->
        if input <> stdin then begin dup2 input stdin; close input end;
        if output <> stdout then begin dup2 output stdout; close output end;
        begin try execvp cmd.(0) cmd
        with _ -> exit 127
        end;
    | id -> Hashtbl.add popen_processes proc id

  let open_process_in cmd =
    let (in_read, in_write) = pipe () in
    let inchan = in_channel_of_descr in_read in
    open_proc cmd (Process_in inchan) stdin in_write [in_read];
    close in_write;
    inchan

  let find_proc_id fun_name proc =
    try
      let pid = Hashtbl.find popen_processes proc in
      Hashtbl.remove popen_processes proc;
      pid
    with Not_found ->
      raise (Unix_error (EBADF, fun_name, ""))

  let rec waitpid_non_intr pid =
    try waitpid [] pid
    with Unix_error (EINTR, _, _) -> waitpid_non_intr pid

  let close_process_in inchan =
    let pid = find_proc_id "close_process_in" (Process_in inchan) in
    close_in inchan;
    snd (waitpid_non_intr pid)

end

module SubprocessWithBatIO = struct
  module Wrapped_in = BatInnerWeaktbl.Make (BatInnerIO.Input) (*input  -> in_channel *)
  let wrapped_in    = Wrapped_in.create 16

  let open_process_in cmd =
    let inchan = Subprocess.open_process_in cmd in
    (* close the fd ourselves (cleanup=false) or close_process_in breaks *)
    let r = BatUnix.input_of_descr ~autoclose:false ~cleanup:false (
      Unix.descr_of_in_channel inchan) in
    Wrapped_in.add wrapped_in r inchan;
    r

  let descr_of_input = BatUnix.descr_of_input

  let close_process_in cin =
    let inchan = Wrapped_in.find wrapped_in cin in
    Wrapped_in.remove wrapped_in cin;
    try Subprocess.close_process_in inchan
    with Not_found ->
      raise (Unix.Unix_error (Unix.EBADF, "close_process_in", ""))

end

let log =
  if false then
    prerr_endline
  else
    ignore

exception Non_zero_exit of Unix.process_status

let require_normal_exit out_pipe =
  let status = SubprocessWithBatIO.close_process_in out_pipe in
  if status <> Unix.WEXITED 0
  then raise (Non_zero_exit status)

let trim_endline str =
  (* XXX not what the spec says, this trims both ends *)
  BatString.trim str

(* Run a command, return stdout data as a string *)
let backtick =
  let trim_endline_ = trim_endline in (* keep the original trim_endline *)
  let backtick ?(trim_endline=false) cmd =
    log (Printf.sprintf "Command %S" (BatString.join " " cmd));
    let out_pipe = SubprocessWithBatIO.open_process_in (Array.of_list cmd) in
    let r = BatIO.read_all out_pipe in
    require_normal_exit out_pipe;
    if trim_endline then trim_endline_ r else r
  in backtick

(* Run a command, read the output into a BigArray.Array1. *)
let subprocess_read_bigarray cmd offset big_array =
  log (Printf.sprintf "Command %S" (BatString.join " " cmd));
  let out_pipe = SubprocessWithBatIO.open_process_in (Array.of_list cmd) in
  let out_fd = SubprocessWithBatIO.descr_of_input out_pipe in
  (* Can't seek a pipe. Read and ignore. *)
  (* XXX lossy int64 conversion *)
  ignore (BatIO.really_nread out_pipe (Int64.to_int offset));
  (* Returns how much was read, may raise. *)
  let r = Unix_util.read out_fd big_array in
  require_normal_exit out_pipe;
  r


let abspath path =
  if not (Filename.is_relative path) then path
  else (Unix.getcwd ()) ^ "/" ^ path

(* Must be lazy, so commands like help and mtab work outside of a git dir. *)
let git_dir_rel_lazy = lazy (
  Unix.putenv "GIT_DISCOVERY_ACROSS_FILESYSTEM" "1";
  let r = backtick ~trim_endline:true ["git"; "rev-parse"; "--git-dir"; ]
  in if r <> "" then r else failwith "Git directory not found."
  )

(* Must be called before fuse runs and changes cwd to / .
   libfuse does that when in its default fork mode. *)
let git_dir_abs_lazy = lazy (
  let lazy git_dir = git_dir_rel_lazy in
  abspath git_dir
  )

let backtick_git ?(trim_endline=false) cmd =
  let lazy git_dir = git_dir_abs_lazy in
  let cmd = "git"::"--git-dir"::git_dir::cmd in
  backtick ~trim_endline cmd

let subprocess_read_bigarray_git cmd offset big_array =
  let lazy git_dir = git_dir_abs_lazy in
  let cmd = "git"::"--git-dir"::git_dir::cmd in
  subprocess_read_bigarray cmd offset big_array

(* Implement percent-encoding (aka urlencode).
   See RFC 3986 section 2.
   http://tools.ietf.org/html/rfc3986#section-2 *)
module PercentEncoding = struct
  let cset_of_range c1 c2 =
    BatISet.add_range (int_of_char c1) (int_of_char c2) BatISet.empty

  let cset_of_string str =
    List.fold_left (fun cset el -> BatISet.add (int_of_char el) cset)
    BatISet.empty (BatString.to_list str)

  let cset_pretty cset =
    BatString.join " " (List.map (fun (c1, c2) ->
      if c1 = c2
      then Printf.sprintf "%C" (char_of_int c1)
      else Printf.sprintf "%C-%C" (char_of_int c1) (char_of_int c2))
    (BatISet.ranges cset))

  (* Those are always safe *)
  let unreserved = cset_of_string
    "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~"
  let gen_delims = cset_of_string ":/?#[]@"
  let sub_delims = cset_of_string "!$&'()*+,;="
  (* Those default to unsafe, but you can mark them as safe *)
  let reserved = BatISet.union gen_delims sub_delims

  let encode bytes safe =
    let safe_here = BatISet.union unreserved (BatISet.inter reserved safe) in
    (*prerr_endline (cset_pretty safe_here);*)
    let encode_char c =
      let ord = int_of_char c in
      if BatISet.mem ord safe_here
      then BatString.of_char c else
        Printf.sprintf "%%%02X" ord
    in
      List.fold_left (fun acc c ->
        acc ^ (encode_char c)) "" (BatString.to_list bytes)
end

(* reserve "," due to fuse option passing.
   " ", used in mountinfo, is encoded by default. *)
let fsname_safe = BatISet.diff
  PercentEncoding.reserved
  (PercentEncoding.cset_of_string ",")

let fsname_lazy = lazy (
  let lazy git_dir_abs = git_dir_abs_lazy in
  PercentEncoding.encode git_dir_abs fsname_safe)

module Hash : sig
  type t
  val of_string : string -> t
  val to_string : t -> string
  (* compare is so we can have HashSet
     Is there a way to refer to the current module?
     We could refer to that instead and maybe make compare private. *)
  val compare : t -> t -> int
  val of_backtick : string list -> t
  val of_rev_parse : string -> t
end = struct
  type t = string (* we could parse the hex, if mem use was a concern *)
  let re = Pcre.regexp "^[0-9a-f]{40}$"
  let of_string v =
    if Pcre.pmatch ~rex:re v then v
    else failwith (Printf.sprintf "Invalid hash: %S" v)
  let to_string v = v
  let compare = String.compare
  let of_backtick cmd =
    of_string (backtick_git ~trim_endline:true cmd)
  let of_rev_parse name =
    try
      of_backtick [ "rev-parse";
          "--revs-only"; "--no-flags"; "--verify"; "--quiet"; name; ]
    with
      |Non_zero_exit (Unix.WEXITED 1)
      |Non_zero_exit (Unix.WEXITED 128) ->
      raise Not_found
end

let describe_tag hash =
  () (* git cat-file tag demo-tag *)

let symlink_target hash =
  (* XXX may be abs or rel, and may go outside the worktree *)
  backtick_git [ "cat-file"; "blob"; Hash.to_string hash; ]


let dir_stats = { (Unix.LargeFile.stat "." (* XXX *)) with
  UL.st_perm = 0o500;
  }
let file_stats = { dir_stats with
  UL.st_kind = Unix.S_REG;
  UL.st_nlink = 1;
  UL.st_perm = 0o400;
  (* /proc uses zero, it works.
   * /sys uses 4k.
   * zero doesn't work with fuse, at least high-level fuse;
   * the reason seems to be fuse prefetching and caching.
   *)
  UL.st_size = Int64.of_int 4096; (* XXX *)
  }
let blob_stats size is_exe = { file_stats with
  UL.st_size = size;
  UL.st_perm = if is_exe then 0o500 else 0o400;
  }

let symlink_stats = { dir_stats with
  UL.st_kind = Unix.S_LNK;
  UL.st_nlink = 1;
  UL.st_perm = 0o400;
  }



type ref_tree_i = (string * ref_tree) list
and ref_tree =
  |RefTreeInternalNode of ref_tree_i
  |RefTreeLeaf of Hash.t


(* prefix, and a subtree we haven't traversed yet *)
type refs_scaff = {
  refs_depth: int; prefix: string; subtree: unit -> ref_tree_i; }
type ref_scaff = { ref_depth: int; ref_hash: Hash.t; ref_reflog_name: string; }
(* used to be shared with log and reflog, hence the name *)
type log_scaff = { log_depth: int; log_hash: Hash.t; log_name: string; }

type dir_like = [
  |`RootScaff
  |`TreesScaff
  |`CommitsScaff
  |`RefsScaff of refs_scaff
  |`TreeHash of Hash.t
  |`CommitHash of Hash.t
  |`RefScaff of ref_scaff
  |`ReflogScaff of log_scaff
  |`LogScaff of Hash.t
  |`CommitParents of Hash.t
  (*| (* gitlink, etc *)*)
  ]

type file_like = [
  |`CommitMsg of Hash.t
  |`CommitDiff of Hash.t
  |`PlainBlob of Hash.t
  |`ExeBlob of Hash.t
  ]

type symlink_like = [
  |`FsSymlink of string
  |`WorktreeSymlink of Hash.t
  ]

type scaffolding = [
  |dir_like
  |file_like
  |symlink_like
  ]



let rec canonical = function
  |`RootScaff -> "."
  |`TreesScaff -> "trees"
  |`RefsScaff { prefix = prefix } ->
      if prefix = "" then "refs" else "refs/" ^ prefix
  |`RefScaff { ref_reflog_name = name } -> "refs/" ^ name
  |`CommitsScaff -> "commits"
  |`TreeHash hash -> (canonical `TreesScaff) ^ "/" ^ (Hash.to_string hash)
  |`CommitHash hash -> (canonical `CommitsScaff) ^ "/" ^ (Hash.to_string hash)

let rec parents_depth depth =
  if depth = 0 then ""
  else "../" ^ parents_depth (depth - 1)

let symlink_to_scaff scaff depth =
  let path = canonical scaff in
  let to_root = parents_depth depth in
  `FsSymlink (to_root ^ path)

let hashtable_keys htbl =
  let acc = ref [] in
  Hashtbl.iter (fun k v -> acc := k::!acc) htbl;
  !acc

module HashSet = BatSet.Make (Hash)

let known_commit_hashes_ = ref HashSet.empty

let known_commit_hashes () =
  HashSet.elements !known_commit_hashes_

let notice_commit_hash hash =
  known_commit_hashes_ := HashSet.add hash !known_commit_hashes_

let tree_of_commit_with_prefix hash prefix =
  (* prefix should be empty or a relative path with no initial slash
   * and no . or .. *)
  Hash.of_rev_parse ((Hash.to_string hash) ^ "^{tree}" ^ ":" ^ prefix )

let commit_parents hash =
  let r = List.map Hash.of_string (BatString.nsplit (backtick_git
    [ "log"; "-n1"; "--format=format:%P"; Hash.to_string hash; ]) " ")
  in List.iter notice_commit_hash r;
  r

let commit_parents_pretty_names hash =
  let hash_s = Hash.to_string hash in
  match commit_parents hash with
  |[] -> []
  |p0::tl -> (hash_s ^ "^")::(BatList.mapi (fun i h ->
      hash_s ^ "^" ^ (string_of_int (i+2)))
      tl)

let parent_symlink merged parent_id depth =
  let merged_s = Hash.to_string merged in
  if not (BatString.starts_with parent_id (merged_s ^ "^"))
  then failwith (Printf.sprintf
        "%S has incorrect syntax for a parent of %S" parent_id merged_s);
  let suffix = BatString.tail parent_id 41 in
  (* human-readable parent indices are off by one, they start at 1 *)
  let parent_idx = if suffix = "" then 1 else int_of_string suffix in
  let hash = List.nth (commit_parents merged) (pred parent_idx) in
  symlink_to_scaff (`CommitHash hash) depth

let lines_of_string str =
  Pcre.split ~pat:"\n" str

let ref_names () =
  (**
   * This result shouldn't be cached, unlike most of the git data model
   * it's not a functional data structure and may mutate.
   *)
  let lines = lines_of_string (backtick_git [ "for-each-ref";
    "--format"; "%(refname) %(objectname)"; ])
  in List.map (fun line ->
    let r, h_s = BatString.rsplit line " " in r, Hash.of_string h_s) lines

let rec ref_tree_add tree path hash =
  (* this traversal relies on the sort order *)
  match tree, path with
  (* git maintains that invariant for us anyway. Except if someone manages to
     create refs/{heads,remotes,tags} as a ref instead of a ref prefix. *)
  |_, [] -> failwith "Can't make an internal node into a leaf"
  |((name, RefTreeInternalNode grand_children)::children_tl), name_::tl
  when name = name_ ->
    (name, RefTreeInternalNode (ref_tree_add grand_children tl hash)
      )::children_tl
  |children, name::[] -> (* sort order *)
      (name, RefTreeLeaf hash)::children
  |children, name::tl -> (* sort order *)
      (name, RefTreeInternalNode (ref_tree_add [] tl hash))::children

(* So we don't have dangling symlinks *)
let skel_tree = [
  "refs", RefTreeInternalNode [
    "heads", RefTreeInternalNode [];
    "remotes", RefTreeInternalNode [];
    "tags", RefTreeInternalNode [];
    ];
  ]

let add_symref_if_exists tree name =
  let lazy git_dir_abs = git_dir_abs_lazy in
  try
    (* The file existence test is to not catch anything that isn't
       a symref or a detached symref. *)
    if not (Sys.file_exists (git_dir_abs ^ "/" ^ name)) then raise Not_found;
    ref_tree_add tree [name] (Hash.of_rev_parse name)
  with
    Not_found -> tree

let ref_tree_uncached () =
  let refs = ref_names () in
  let tree = ref skel_tree in
  List.iter (fun (refname, hash) ->
    let refpath = BatString.nsplit refname "/" in
    tree := ref_tree_add !tree refpath hash;
    )
    refs;
  List.iter (fun name -> tree := add_symref_if_exists !tree name) [
      "HEAD"; "FETCH_HEAD"; "ORIG_HEAD"; "MERGE_HEAD"; ];
  !tree

(* Time-based caching decorator.
   Takes fn: () -> 'a, delay, returns () -> 'a *)
let with_caching fn delay_float_secs =
  let cache = ref None in fun () ->
  match !cache with
  |None ->
      log "cache miss";
      let v = fn () in cache := Some (v, Unix.time ()); v
  |Some (_, tstamp) when Unix.time () > tstamp +. delay_float_secs ->
      log "cache refresh";
      let v = fn () in cache := Some (v, Unix.time ()); v
  |Some (cached, _) ->
      log "cache hit";
      cached

let ref_tree =
  with_caching ref_tree_uncached ref_expiration_secs

let parse_rev_list cmd =
  let r = lines_of_string (backtick_git cmd)
  in List.iter (fun h_s ->
    let h = Hash.of_string h_s in
    notice_commit_hash h)
    r;
  r

let decimal_width entries =
  let n = List.length entries in
  n - 1 |> float_of_int |> log10 |> ceil |> int_of_float

let reflog_regexp = Pcre.regexp "^(.*)@{([0-9]+)}$"
let log_regexp = Pcre.regexp "^(.*)~([0-9]+)$"

let reflog_entries name =
  (* XXX There's something very wrong taking the reflog of a tag.
     This appears to be a git bug. *)
  parse_rev_list [ "rev-list"; "-g"; name; ]

let reflog_entries_pretty_names name hash =
  let entries = reflog_entries name in
  let width = decimal_width entries in
  BatList.mapi (fun i h ->
    "@{" ^ (Printf.sprintf "%0*d" width i) ^ "}") entries

let reflog_entry name child depth =
  (* Would be nice to reverify consistency in case the ref moved. *)
  let fail () = failwith (Printf.sprintf
        "%S has incorrect syntax for a reflog entry of %S" child name) in
  let substr = try
    Pcre.exec ~rex:reflog_regexp child
  with
    Not_found -> fail () in
  let refname = Pcre.get_substring substr 1 in
  if refname <> "" then fail ();
  let child_hash = Hash.of_rev_parse (name ^ child)
  in symlink_to_scaff (`CommitHash child_hash) depth

let log_entries hash =
  parse_rev_list [ "rev-list"; Hash.to_string hash; ]

let log_entries_pretty_names hash =
  let entries = log_entries hash in
  let width = decimal_width entries in
  BatList.mapi (fun i h ->
    "~" ^ (Printf.sprintf "%0*d" width i)) entries

let log_entry hash child =
  let hash_s = Hash.to_string hash in
  let fail () = failwith (Printf.sprintf
        "%S has incorrect syntax for a log entry of %S" child hash_s) in
  let substr = try
    Pcre.exec ~rex:log_regexp child
  with
    Not_found -> fail () in
  let refname = Pcre.get_substring substr 1 in
  if refname <> "" then fail ();
  let child_hash = Hash.of_rev_parse (hash_s ^ child; )
  in `FsSymlink ("../../" ^ (Hash.to_string child_hash))


(* association list for the fs root *)
(* takes unit, not pure, because branch state and symbolic-ref state
   may change externally *)
let root_al () = [
  "heads", `FsSymlink "refs/refs/heads";
  "remotes", `FsSymlink "refs/refs/remotes";
  "tags", `FsSymlink "refs/refs/tags";
  "HEAD", `FsSymlink "refs/HEAD";
  "trees", `TreesScaff;
  "commits", `CommitsScaff;
  (* stateful *)
  "refs", `RefsScaff { prefix = ""; subtree = ref_tree; refs_depth = 0; };
  ]


let tree_of_commit hash =
  tree_of_commit_with_prefix hash ""

let commit_symlink_of_hash hash depth =
  let scaff = `CommitHash hash in
  symlink_to_scaff scaff depth

let tree_symlink_of_commit hash depth =
  let scaff = `TreeHash (tree_of_commit hash) in
  symlink_to_scaff scaff depth


let ls_tree_regexp = Pcre.regexp "(100644 blob|100755 blob|120000 blob|040000 tree) ([0-9a-f]+)\t([^\\x00]+)\\x00"

let tree_children_uncached hash =
  let lines = backtick_git [ "ls-tree";
      "--full-tree"; "-z"; "--"; Hash.to_string hash; ] in
  let rec parse lines offset =
    if String.length lines = offset then []
    else let substrs = try
      Pcre.exec ~rex:ls_tree_regexp ~pos:offset lines
    with Not_found -> failwith (
      Printf.sprintf "Ill-formatted ls-tree lines: %S" (
        BatString.slice ~first:offset lines)) in
    match Pcre.get_substrings ~full_match:false substrs
    with
      |[| kind_s; hash_s; name |] ->
        let match_start, match_end = Pcre.get_substring_ofs substrs 0 in
        let hash = Hash.of_string hash_s in
        let scaff = match kind_s with
        |"100644 blob" -> `PlainBlob hash
        |"100755 blob" -> `ExeBlob hash
        |"120000 blob" -> `WorktreeSymlink hash
        |"040000 tree" -> `TreeHash hash
        |_ -> assert false
        in (name, scaff)::(parse lines match_end)
      |_ -> assert false
  in parse lines 0

let tree_children, known_tree_hashes =
  let children_cache = Hashtbl.create 16
  in let tree_children hash =
    try
      Hashtbl.find children_cache hash
    with Not_found ->
      let children = tree_children_uncached hash in
      Hashtbl.add children_cache hash children;
      children
  and known_tree_hashes () =
    hashtable_keys children_cache
  in tree_children, known_tree_hashes

let tree_child hash child =
  List.assoc child (tree_children hash)
let tree_children_names hash =
  List.map fst (tree_children hash)

let scaffolding_child (scaff : scaffolding) child : scaffolding =
  match scaff with
  |#dir_like as scaff -> begin match scaff with
    |`RootScaff -> List.assoc child (root_al ())
    |`TreesScaff ->
        `TreeHash (Hash.of_string child) (* XXX should check for existence *)
    |`RefsScaff { prefix = prefix; subtree = children; refs_depth = depth; } ->
      begin
        let prefix1 = if prefix = "" then child else prefix ^ "/" ^ child
        and children_val = children ()
        in match List.assoc child children_val with
          |RefTreeLeaf hash -> `RefScaff { ref_hash = hash;
              ref_depth = depth + 1; ref_reflog_name = prefix1; }
          |RefTreeInternalNode children2 -> `RefsScaff {
              prefix = prefix1; subtree = (fun () -> children2); refs_depth = depth + 1; }
        end
    |`CommitsScaff -> let h = Hash.of_string child in
        notice_commit_hash h;
        `CommitHash h
    |`TreeHash hash -> tree_child hash child
    |`ReflogScaff { log_name = name; log_depth = depth; } ->
        reflog_entry name child (depth + 1)
    |`LogScaff hash -> log_entry hash child
    |`RefScaff { ref_hash = hash; ref_depth = depth; } when child = "current" ->
        commit_symlink_of_hash hash (depth + 1)
    (* We keep both hash and name, to force a ref_tree refresh
       when the first reflog entry doesn't match the hash. *)
    |`RefScaff { ref_hash = hash; ref_reflog_name = name; ref_depth = depth; }
      when child = "reflog" -> `ReflogScaff {
            log_name = name; log_hash = hash; log_depth = depth + 1; }
    |`RefScaff { ref_hash = hash; ref_reflog_name = name; ref_depth = depth; }
      when child = "log" -> `FsSymlink "current/log"
    |`RefScaff _ when child = "worktree" ->
        `FsSymlink "current/worktree"
    |`RefScaff _ -> raise Not_found

    |`CommitHash hash when child = "log" -> `LogScaff hash
    |`CommitHash hash when child = "msg" -> `CommitMsg hash
    |`CommitHash hash when child = "diff" -> `CommitDiff hash
    |`CommitHash hash when child = "parents" -> `CommitParents hash
    |`CommitHash hash when child = "worktree" ->
        tree_symlink_of_commit hash 2
    |`CommitHash hash -> raise Not_found
    |`CommitParents hash ->
        (* here, child confusingly means parent in git semantics *)
        parent_symlink hash child 3
  end
  |#scaffolding -> (* symlinks aren't directories either, fuse resolves them for us *)
      raise (Unix.Unix_error
        (Unix.ENOTDIR, "scaffolding_child", ""))

let list_children (scaff : scaffolding) =
  match scaff with
  |#dir_like as scaff -> begin match scaff with
    |`RootScaff ->
        List.map fst (root_al ())
    |`TreesScaff -> (* Not complete, but we won't scan the whole repo here. *)
        List.map Hash.to_string (known_tree_hashes ())
    |`CommitsScaff -> (* Not complete either. *)
        List.map Hash.to_string (known_commit_hashes ())
    |`RefsScaff { subtree = children } ->
        List.map fst (children ())
    |`RefScaff _ -> [ "current"; "worktree"; "log"; "reflog"; ]
    |`CommitHash _ -> [ "msg"; "diff"; "worktree"; "parents"; "log"; ]
    |`ReflogScaff { log_name = name; log_hash = hash; } ->
        reflog_entries_pretty_names name hash
    |`LogScaff hash ->
        log_entries_pretty_names hash
    |`TreeHash hash -> tree_children_names hash
    |`CommitParents hash -> commit_parents_pretty_names hash
  end
  |#scaffolding ->
      raise (Unix.Unix_error
        (Unix.ENOTDIR, "list_children", ""))


let lookup caller path =
  let rec lookup_r scaff = function
    |[] -> scaff
    |dir::rest ->
  lookup_r (scaffolding_child scaff dir) rest
  in match BatString.nsplit path "/" with
  |""::""::[] -> `RootScaff (* / *)
  |""::path_comps -> begin
    (* /nonempty, or possibly // if fuse doesn't filter *)
    try
      lookup_r `RootScaff path_comps
    with Not_found ->
      raise (Unix.Unix_error (Unix.ENOENT, caller, path))
    end
  |_ -> assert false (* fuse path must start with a slash *)



let fh_data = Hashtbl.create 16

let next_fh = ref 0

let make_fh path scaff =
  let fh = !next_fh in
  incr next_fh;
  Hashtbl.add fh_data fh scaff;
  (fh, scaff)

let clear_fh fh =
  Hashtbl.remove fh_data fh

let lookup_fh fh =
  Hashtbl.find fh_data fh

(* Use this for open / opendir, the ones that need a file handle *)
let lookup_and_open caller path =
  let scaff = lookup caller path in
  make_fh path scaff


let blob_size_uncached hash =
  Int64.of_string (backtick_git ~trim_endline:true [ "cat-file";
      "-s"; Hash.to_string hash; ])

let blob_size =
  let cache = Hashtbl.create 16
  in let blob_size hash =
    try
      Hashtbl.find cache hash
    with Not_found ->
      let r = blob_size_uncached hash in
      Hashtbl.add cache hash r;
      r
  in blob_size

let blob_stats_by_hash hash is_exe =
  blob_stats (blob_size hash) is_exe


let do_getattr path =
  let scaff = lookup "stat" path in
  match scaff with
  |#dir_like -> dir_stats
  |#symlink_like -> symlink_stats
  |#file_like as scaff -> match scaff with
    |`CommitMsg _
    |`CommitDiff _ -> file_stats

    |`PlainBlob hash -> blob_stats_by_hash hash false
    |`ExeBlob hash -> blob_stats_by_hash hash true


let do_opendir path flags =
(*log ("Path is: " ^ path);*)
  let fh, scaff = lookup_and_open "opendir" path in
  match scaff with
  |#dir_like -> Some fh
  |#scaffolding ->
      raise (Unix.Unix_error (Unix.ENOTDIR, "opendir", path))

let do_releasedir path flags fh =
  clear_fh fh

let do_readdir path fh =
  try
    let scaff = lookup_fh fh in
    "."::".."::(list_children scaff)
  with Not_found ->
    (*log (Printf.sprintf "Can't readdir “%S”" path);*)
    assert false (* because opendir passed *)

let do_readlink path =
  let scaff = lookup "readlink" path in
  match scaff with
  |#symlink_like as scaff -> begin match scaff with
    |`FsSymlink target -> target
    |`WorktreeSymlink hash ->
        symlink_target hash (* XXX: these are allowed to go outside the tree *)
  end
  |#scaffolding -> raise (Unix.Unix_error (Unix.EINVAL, "readlink (not a symlink)", path))

let do_fopen path flags =
  let fh, scaff = lookup_and_open "fopen" path in
  match scaff with
  |#file_like -> Some fh
  (* symlinks are resolved on the fuse side, we never see them opened. *)
  |#scaffolding -> raise (Unix.Unix_error (Unix.EINVAL, "fopen (not a file)", path))

let do_release path flags fh =
  clear_fh fh

(* Read file data into a Bigarray.Array1.

   libfuse-ocaml takes a string, making it simpler than ocamlfuse.
   *)
let do_read path buf ofs fh =
  try
    let scaff = lookup_fh fh in
    match scaff with
    |#file_like as scaff -> begin match scaff with
      |`PlainBlob hash |`ExeBlob hash ->
          subprocess_read_bigarray_git [ "cat-file"; "blob"; Hash.to_string hash; ] ofs buf
      |`CommitMsg hash ->
          (* Not exactly the raw message, but there's no api to get it.
           * %s and %b don't go far. There's rewrapping and stuff. *)
          subprocess_read_bigarray_git [ "log"; "--max-count=1"; Hash.to_string hash; ] ofs buf
      |`CommitDiff hash ->
        subprocess_read_bigarray_git [ "format-patch";
          "-C"; "--max-count=1"; "--stdout"; Hash.to_string hash; ] ofs buf
    end
    |#scaffolding -> assert false (* we filtered at fopen time *)
    with Not_found ->
      assert false (* because open passed *)

let fuse_ops = {
      Fuse.default_operations with
        Fuse.getattr = do_getattr;
        Fuse.opendir = do_opendir;
        Fuse.releasedir = do_releasedir;
        Fuse.readdir = do_readdir;
        Fuse.readlink = do_readlink;
        Fuse.fopen = do_fopen;
        Fuse.release = do_release;
        Fuse.read = do_read;
    }

let mountpoint_lazy =
  lazy (let lazy git_dir = git_dir_rel_lazy in git_dir ^ "/fs")


let fs_subtype = Filename.basename Sys.argv.(0)

let fs_type = "fuse." ^ fs_subtype

let mtab_lines () =
  BatEnum.filter_map (fun line ->
    match BatString.nsplit line " " with
    |_::_::_::"/"::mountpoint::_::"-"::an_fs_type::git_dir_quoted::_
    when an_fs_type = fs_type ->
      (* XXX mountpoint has octal escapes, decode that? *)
      Some (git_dir_quoted, mountpoint)
    |_ -> None
    ) (BatFile.lines_of "/proc/self/mountinfo")

let is_mounted () =
  let lazy fsname = fsname_lazy in
  BatEnum.exists (fun (git_dir_quoted, mountpoint) ->
    git_dir_quoted = fsname)
    (mtab_lines ())

let cmd_mount ?(debug=false) ?(allow_other=false) () =
  let lazy mountpoint = mountpoint_lazy in
  let lazy fsname = fsname_lazy in
  (*log fsname;*)
  if is_mounted ()
  then
    prerr_endline (Printf.sprintf "Mounted on %S" mountpoint)
  else begin
    begin try Unix.mkdir mountpoint 0o755
    with Unix.Unix_error (Unix.EEXIST, _, _) -> () end;
    prerr_endline (Printf.sprintf "Mounting on %S" mountpoint);
    let fuse_args = [
      "-o"; "ro";
      (* fuse doesn't guess the subtype anymore, if we give it fsname *)
      "-osubtype=" ^ fs_subtype;
      "-ofsname=" ^ fsname;
      mountpoint;
      ] in
    let fuse_args = if debug then "-s"::"-d"::fuse_args else fuse_args in
    let fuse_args = if allow_other then "-o"::"allow_other"::fuse_args else fuse_args in
    let fuse_args = fs_subtype::fuse_args in
    Fuse.main (Array.of_list fuse_args) fuse_ops
  end

let cmd_umount () =
  let lazy mountpoint = mountpoint_lazy in
  try
    ignore (backtick ["fusermount"; "-u"; "--"; mountpoint])
  with
    Non_zero_exit status -> ()

let cmd_show_mountpoint () =
  let lazy mountpoint = mountpoint_lazy in
  print_endline mountpoint

let cmd_is_mounted () =
  if is_mounted () then
    exit 0
  else
    exit 1

let cmd_mtab () =
  BatEnum.iter (fun (git_dir_quoted, mountpoint) ->
    print_endline mountpoint) (mtab_lines ())

let usage () =
  prerr_endline "Usage: git fs [mount [--allow-other]|umount|show-mountpoint|is-mounted|mtab|help]"

let cmd_help = usage

let cmd_fuse_help () =
  Fuse.main [| Sys.argv.(0); "--help"; |] fuse_ops

let _ =
  match Sys.argv with
  (* TODO use an option parsing library? *)
  |[| _ |] -> cmd_mount ()
  |[| _; "mount" |] -> cmd_mount ()
  (* --allow-other / -o allow_other lets other users access the filesystem.
   * They might get read privileges to more of the repository
   * than if they attempted to run git fs themselves. *)
  |[| _; "mount"; "--allow-other" |] -> cmd_mount ~allow_other:true ()
  |[| _; "debug" |] -> cmd_mount ~debug:true () (* For development *)
  |[| _; "umount" |] -> cmd_umount ()
  |[| _; "show-mountpoint" |] -> cmd_show_mountpoint ()
  |[| _; "is-mounted" |] -> cmd_is_mounted ()
  |[| _; "mtab" |] -> cmd_mtab ()
  |[| _; "help" |] -> cmd_help ()
  |[| _; "fuse-help" |] -> cmd_fuse_help () (* For development *)
  |_ -> begin usage (); exit 2; end

