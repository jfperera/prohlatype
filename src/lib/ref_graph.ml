
open Util
open Graph
module A = Alleles

(* TODO:
  - Hashcons the sequences
  - Turn fold_succ_e from O(n) into something better
*)

type alignment_position = int [@@deriving eq, ord]
type start = alignment_position * (A.allele [@equal A.equal] [@compare A.compare]) [@@deriving eq, ord]
type end_ = alignment_position [@@deriving eq, ord]
type sequence = string [@@deriving eq, ord]

(* start end pairs *)
type sep = { start : start ; end_ : end_ } [@@deriving eq, ord]

module Nodes = struct

  type t =
    | S of start
    | E of end_
    | B of alignment_position * int       (* Boundary of position and count *)
    | N of alignment_position * sequence  (* Sequences *)
    [@@deriving eq, ord]

  let vertex_name ?(short=true) = function
    | S (n, s)  -> sprintf "S%d-%s" n s
    | E n       -> sprintf "E%d" n
    | B (p, n)  -> sprintf "B%d-%d" n p
    | N (n, s)  -> sprintf "%d%s" n (if short then short_seq s else s)

  let position = function
    | S (p, _) | E p | B (p, _) | N (p, _)  -> p

  let inside pos = function
    | S (p, _) | E p | B (p, _) -> p = pos
    | N (p, s) -> p <= pos && pos < p + String.length s

  let inside_seq p s ~pos =
    p < pos && pos < p + String.length s

  let compare_by_position_first n1 n2 =
    let compare_int (i1 : int) (i2 : int) = Pervasives.compare i1 i2 in
    let r = compare_int (position n1) (position n2) in
    if r = 0 then compare n1 n2 else r

  let hash = Hashtbl.hash
end

module Edges = struct
  type t = A.Set.t
  let hash = Hashtbl.hash
  let compare = A.Set.compare
  let equal = A.Set.equals
  let default = A.Set.empty ()
end

module G = Imperative.Digraph.ConcreteLabeled(Nodes)(Edges)

exception Found of Nodes.t

let next_node_along g aindex allele ~from =
  try
    G.fold_succ_e (fun (_, bt, vs) n ->
        if A.Set.is_set aindex bt allele then raise (Found vs) else n)
      g from None
  with Found v ->
    Some v

let fold_along_allele g aindex allele ~start ~f ~init =
  if not (G.mem_vertex g start) then
    invalid_argf "%s is not a vertex in the graph." (Nodes.vertex_name start)
  else
    let next = next_node_along g aindex allele in
    let rec loop from (acc, stop) =
      match stop with
      | `Stop     -> acc
      | `Continue ->
          match next ~from with
          | None    -> acc
          | Some vs -> loop vs (f acc vs)
    in
    loop start (f init start)

let between g start stop =
  let ng = G.create () in
  G.add_vertex ng start;
  let rec add_from node =
    G.iter_succ_e (fun ((_, _, n) as e) ->
      G.add_vertex ng n;
      G.add_edge_e ng e;
      if n <> stop then add_from n)
      g node
  in
  add_from start;
  ng

type t =
  { g       : G.t
  ; aindex  : A.index
  ; bounds  : sep list A.Map.t
  }

(** Output **)

(* TODO:
  - When constructing the dot files, it would be nice if the alleles (edges),
    were in some kind of consistent order. *)

(** [starts_by_position g] returns an associated list of alignment_position and
    an a set of alleles that start at that position. *)
let starts_by_position { aindex; bounds; _ } =
  Alleles.Map.fold aindex bounds ~init:[] ~f:(fun asc sep_lst allele ->
    List.fold_left sep_lst ~init:asc ~f:(fun asc sep ->
      let pos = fst sep.start in
      try
        let bts = List.assoc pos asc in
        Alleles.Set.set aindex bts allele;
        asc
      with Not_found ->
        (pos, Alleles.Set.singleton aindex allele) :: asc))

(** Compress the start nodes; join all the start nodes that have the same
    alignment position into one node. *)
let create_compressed_starts g =
  let start_asc = starts_by_position g in
  let ng = G.copy g.g in
  let open Nodes in
  List.iter start_asc ~f:(fun (pos, allele_set) ->
    if Alleles.Set.cardinal allele_set > 1 then begin
      let a_str = Alleles.Set.to_string ~compress:true g.aindex allele_set in
      let node = G.V.create (S (pos, a_str)) in
      G.add_vertex ng node;
      Alleles.Set.iter g.aindex allele_set ~f:(fun allele ->
        let rm = S (pos, allele) in
        G.iter_succ (fun sv ->
          try
            let eset = G.find_edge ng node sv |> G.E.label in
            Alleles.Set.set g.aindex eset allele
          with Not_found ->
            let bt = Alleles.Set.singleton g.aindex allele in
            G.add_edge_e ng (G.E.create node bt sv)) ng rm;
        G.remove_vertex ng rm)
    end);
  { g = ng; aindex = g.aindex; bounds = g.bounds }

let insert_newline ?(every=120) ?(token=';') s =
  String.to_character_list s
  |> List.fold_left ~init:(0,[]) ~f:(fun (i, acc) c ->
      if i > every && c = token then
        (0, '\n' :: c :: acc)
      else
        (i + 1, c :: acc))
  |> snd
  |> List.rev
  |> String.of_character_list

let output_dot ?(human_edges=true) ?(compress_edges=true) ?(compress_start=true)
  ?(insert_newlines=true) ?short ?max_length fname t =
  let { aindex; g; _} = if compress_start then create_compressed_starts t else t in
  let oc = open_out fname in
  let module Dot = Graphviz.Dot (
    struct
      include G
      let graph_attributes _g = []
      let default_vertex_attributes _g = []
      let vertex_name v =
        let s = sprintf "\"%s\"" (Nodes.vertex_name ?short v) in
        if insert_newlines then insert_newline s else s

      let vertex_attributes _v = [`Shape `Box]
      let get_subgraph _v = None

      let default_edge_attributes _t = [`Color 4711]
      let edge_attributes e =
        let compress = compress_edges in
        let s =
          if human_edges then
            A.Set.to_human_readable ~compress ?max_length aindex (G.E.label e)
          else
            A.Set.to_string ~compress aindex (G.E.label e)
        in
        if insert_newlines then
          [`Label ( insert_newline s) ]
            else
          [`Label s ]

    end)
  in
  Dot.output_graph oc g;
  close_out oc

let output ?human_edges ?compress_edges ?compress_start ?insert_newlines
  ?max_length ?(pdf=true) ?(open_=true) ~short fname t =
  output_dot ?human_edges ?compress_edges ?compress_start ?max_length ~short (fname ^ ".dot") t;
  let r =
    if pdf then
      Sys.command (sprintf "dot -Tpdf %s.dot -o %s.pdf" fname fname)
    else
      -1
  in
  if r = 0 && open_ then
    Sys.command (sprintf "open %s.pdf" fname)
  else
    r

let save fname g =
  let oc = open_out fname in
  Marshal.to_channel oc g [];
  close_out oc

let load fname =
  let ic = open_in fname in
  let g : G.t = (Marshal.from_channel ic) in
  close_in ic;
  g

(** Construction *)

let inv_argf ?(prefix="") fmt = ksprintf invalid_arg ("%s" ^^ fmt) prefix

let relationship pos v =
  let open Nodes in
  let end_pos p s = p + String.length s in
  match v with
  | S _ | E _                             -> `Ignore
  | B (p, _) when pos < p                 -> `Before p
  | N (p, _) when pos < p                 -> `Before p
  | B (p, _) when pos = p                 -> `Exact
  | N (p, s) when pos = p                 -> `Exact
  | B _                                   -> `After
  | N (p, s) when pos < end_pos p s       -> `In (p, s)
  | N _ (*p, s) when pos >= end_pos p s*) -> `After

(*first_start, last_end, end_to_next_start_assoc *)
let reference_starts_and_ends lst =
  match lst with
  | []                  -> inv_argf "Reference has no start and ends"
  | {start; end_} :: [] -> start, end_, []
  | {start; end_} :: t  ->
    let rec loop ep acc = function
      | []                  -> inv_argf "stop before empty"
      | {start; end_} :: [] -> end_, (ep, start) :: acc
      | {start; end_} :: t  -> loop end_ ((ep, start) :: acc) t
    in
    let e, l = loop end_ [] t in
    start, e, l

let add_reference_elems g aindex allele ref_elems =
  let open Mas_parser in
  let open Nodes in
  let bse () = A.Set.singleton aindex allele in
  let add_start start_pos lst =
    let st = start_pos, allele in
    `Started (st, G.V.create (S st)) :: lst
  in
  let add_end end_pos ~st ~prev lst =
    G.add_edge_e g (G.E.create prev (bse ()) (G.V.create (E end_pos)));
    `Ended (st, end_pos) :: lst
  in
  let add_boundary ~st ~prev ~idx ~pos lst =
    let boundary_node = G.V.create (B (pos, idx)) in
    G.add_edge_e g (G.E.create prev (bse ()) boundary_node);
    `Started (st, boundary_node) :: lst
  in
  let add_seq ~st ~prev start s lst =
    let sequence_node = G.V.create (N (start, s)) in
    G.add_edge_e g (G.E.create prev (bse ()) sequence_node);
    `Started (st, sequence_node) :: lst
  in
  List.fold_left ref_elems ~init:[] ~f:(fun state e ->
      match state, e with
      | []            , Start start_pos               -> add_start start_pos state
      | `Ended _ :: _ , Start start_pos               -> add_start start_pos state
      | []            , Boundary _
      | `Ended _ :: _ , Boundary _                    -> state        (* ignore *)
      | []            , al_el
      | `Ended _ :: _ , al_el                         ->
          inv_argf "Unexpected %s before start for %s"
            (al_el_to_string al_el) allele
      | `Started (st, prev) :: tl, End end_pos          -> add_end end_pos ~st ~prev tl
      | `Started (st, prev) :: tl, Boundary {idx; pos } -> add_boundary ~st ~prev ~idx ~pos tl
      | `Started (st, prev) :: tl, Sequence {start; s } -> add_seq ~st ~prev start s tl
      | `Started (_, _) :: _,      Gap _                -> state       (* ignore gaps *)
      | `Started (_, _) :: tl,     Start sp             ->
          inv_argf "Unexpected second start at %d for %s" sp allele)
  |> List.map ~f:(function
      | `Started _ -> inv_argf "Still have a Started in %s ref" allele
      | `Ended (start, end_) -> { start; end_})
  |> List.sort ~cmp:(fun s1 s2 -> compare_start s1.start s2.start)

let test_consecutive_elements =
  let open Mas_parser in
  let open Nodes in
  function
  | `Gap close_pos      ->
      begin function
      | Sequence {start; s} :: tl when start = close_pos ->
          let new_close = start + String.length s in
          `Continue (Some (N (start, s)), (`Sequence new_close), tl)
      | _ -> `Close close_pos
      end
  | `Sequence close_pos ->
      begin function
      | Gap { start; length} :: tl when start = close_pos ->
          let new_close = start + length in
          `Continue (None, (`Gap new_close), tl)
      | _ -> `Close close_pos
      end

let add_non_ref g reference aindex (first_start, last_end, end_to_next_start_assoc) allele alt_lst =
  let open Mas_parser in
  let open Nodes in
  let first_start_node = S first_start in
  let last_end_node = E last_end in
  let end_to_start_nodes = List.map ~f:(fun (e, s) -> E e, S s) end_to_next_start_assoc in
  let next_reference ~msg from =
    match next_node_along g aindex reference ~from with
    | Some n -> n
    | None   -> try List.assoc from end_to_start_nodes
                with Not_found -> invalid_arg msg
  in
  let do_nothing _ _ = () in
  let advance_until ~visit ~prev ~next pos =
    let rec forward node msg =
      loop node (next_reference ~msg node)
    and loop prev next =
      if next = first_start_node then
        forward next "No next after reference Start!"
      else if next = last_end_node then
        `AfterLast prev
      else
        match relationship pos next with
        | `Ignore    -> forward next (sprintf "Skipping %s" (vertex_name next))
        | `Before ap -> `InGap (prev, next, ap)
        | `Exact     -> `AtNext (prev, next)
        | `In (p, s) -> `InsideNext (prev, next, p, s)
        | `After     -> visit prev next;
                        forward next "Not at End, should have next!"
    in
    loop prev next
  in
  let split_in ~prev ~visit ~next pos =
    let split_and_rejoin p s node =
      let open Nodes in
      let index = pos - p in
      let fs, sn = String.split_at s ~index in
      let pr = G.pred_e g node in
      let su = G.succ_e g node in
      G.remove_vertex g node;
      let v1 = N (p, fs) in
      G.add_vertex g v1;
      let s_inter =
        List.fold_left pr ~init:(A.Set.init aindex)
            ~f:(fun bta (p, bt, _) ->
                  G.add_edge_e g (G.E.create p bt v1);
                  A.Set.union bt bta)
      in
      let v2 = N (pos, sn) in
      G.add_vertex g v2;
      G.add_edge_e g (G.E.create v1 s_inter v2);
      A.Set.clear aindex s_inter allele;
      List.iter su ~f:(fun (_, e, s) -> G.add_edge_e g (G.E.create v2 e s));
      (v1, v2)
    in
    match advance_until ~prev ~next ~visit pos with
    | `InsideNext (pv, nv, p, s) ->
        let v1, v2 = split_and_rejoin p s nv in
        visit pv v1;
        `AtNext (v1, v2)
    | `AfterLast _ as al -> al
    | `InGap _ as ig     -> ig
    | `AtNext _ as an    -> an
  in
  let add_allele_edge pv nv =
    try
      let eset = G.find_edge g pv nv |> G.E.label in
      A.Set.set aindex eset allele
    with Not_found ->
      let bt = A.Set.singleton aindex allele in
      G.add_edge_e g (G.E.create pv bt nv)
  in
  let rec advance_until_boundary ~visit ~prev ~next pos idx =
    let rec forward node msg =
      loop node (next_reference ~msg node)
    and loop pv nv =
      match nv with
      | S _ | E _ -> forward nv "Skipping start End"
      | B (p, c) when p = pos ->
          if c <> idx then
            inv_argf "Boundary at %d position diff from reference %d count %d"
              p c idx
          else
            pv, nv
      | B (p, _)
      | N (p, _) when p < pos ->
          visit pv nv;
          forward nv (sprintf "Trying to find B %d %d after %d" pos idx p)
      | B (p, c) (*when p > pos*) ->
          inv_argf "Next Boundary %d %d after desired boundary %d %d"
            p c pos idx
      | N (p, _) ->
          inv_argf "Next Sequence position: %d at or after desired boundary pos %d (idx %d)"
            p pos idx
    in
    loop prev next
  in
  (* How we close back with the reference *)
  let rec rejoin_after_split ~prev ~next split_pos state ~new_node lst =
    match split_in ~prev ~next ~visit:do_nothing split_pos with
    | `AfterLast _          -> solo_loop state new_node lst
    | `InGap (pv, next, ap) -> ref_gap_loop state ~prev:new_node next ap lst
    | `AtNext (_pv, next)   -> add_allele_edge new_node next;
                               main_loop state ~prev:new_node ~next lst
  (* In the beginning we have not 'Start'ed ->
    Loop through the alignment elemends:
      - discarding Boundaries and Gaps
      - on a Start find the position in reference and start correct loop
      - complaining on anything other than a Start *)
  and start_loop previous_starts_and_ends lst =
    let rec find_start_loop = function
      | Boundary _ :: t
      | Gap _ :: t      -> find_start_loop t (* Ignore Gaps & Boundaries before Start *)
      | Start p :: t    -> Some ( p, t)
      | []              ->
        begin
          match previous_starts_and_ends with
          | [] -> inv_argf "Failed to find start for %s." allele
          | ls -> None
        end
      | s :: _          -> inv_argf "Encountered %s in %s instead of Start"
                            (al_el_to_string s) allele
    in
    match find_start_loop lst with
    | None -> previous_starts_and_ends (* fin *)
    | Some (start_pos, tl) ->
        let start = start_pos, allele in
        let state = start, previous_starts_and_ends in
        let new_node = G.V.create (S start) in
        (* we can think of a start as as a Gap *)
        close_position_loop state ~prev:first_start_node ~next:first_start_node
          ~allele_node:new_node (`Gap start_pos) tl
  and add_end (start, os) end_ prev tl =
    add_allele_edge prev (G.V.create (E end_));
    let ns = { start; end_ } :: os in
    if tl = [] then
      ns  (* fin *)
    else
      start_loop ns tl
  (* When the only thing that matters is the previous node. *)
  and solo_loop state prev = function
    | []                        -> inv_argf "No End at allele sequence: %s" allele
    | Start p :: _              -> inv_argf "Another start %d in %s allele sequence." p allele
    | End end_pos :: tl         -> add_end state end_pos prev tl
    | Boundary { idx; pos} :: t -> let boundary_node = G.V.create (B (pos, idx)) in
                                   add_allele_edge prev boundary_node;
                                   solo_loop state boundary_node t
    | Sequence { start; s} :: t -> let sequence_node = G.V.create (N (start, s)) in
                                   add_allele_edge prev sequence_node;
                                   solo_loop state sequence_node t
    | Gap _ :: t                -> solo_loop state prev t
  (* When traversing a reference gap. We have to keep check allele elements
    position to check when to join back with the next reference node. *)
  and ref_gap_loop state ~prev ref_node ref_pos = function
    | []                                -> inv_argf "No End at allele sequence: %s" allele
    | Start p :: _                      -> inv_argf "Another start %d in %s allele sequence." p allele
    | (End end_pos :: tl) as lst        ->
        if end_pos <= ref_pos then
          add_end state end_pos prev tl
        else (* end_pos > ref_pos *)
          let () = add_allele_edge prev ref_node in
          main_loop state ~prev ~next:ref_node lst
    | (Boundary { idx; pos} :: tl) as l ->
        if pos < ref_pos then
          inv_argf "Allele %s has a boundary %d at %d that is in ref gap ending %d."
            allele idx pos ref_pos
        else if pos = ref_pos then
          if ref_node = B (pos, idx) then
            let () = add_allele_edge prev ref_node in
            main_loop state ~prev ~next:ref_node tl
          else
            inv_argf "Allele %s has a boundary %d at %d where ref gap ends %d."
              allele idx pos ref_pos
        else
          let () = add_allele_edge prev ref_node in
          main_loop state ~prev ~next:ref_node l
    | (Sequence { start; s} :: tl) as l ->
        if start > ref_pos then begin
          add_allele_edge prev ref_node;
          main_loop state ~prev ~next:ref_node l
        end else
          let new_node = G.V.create (N (start, s)) in
          let () = add_allele_edge prev new_node in
          let close_pos = start + String.length s in
          if close_pos <= ref_pos then
            ref_gap_loop state ~prev:new_node ref_node ref_pos tl
          else (* close_pos > ref_pos *)
            rejoin_after_split ~prev:ref_node ~next:ref_node close_pos state
              ~new_node tl
    | (Gap { start; length} :: tl) as l ->
        if start > ref_pos then begin
          add_allele_edge prev ref_node;
          main_loop state ~prev ~next:ref_node l
        end else
          let close_pos = start + length in
          if close_pos <= ref_pos then
            ref_gap_loop state ~prev ref_node ref_pos tl
          else (* close_pos > ref_pos *)
            rejoin_after_split ~prev:ref_node ~next:ref_node close_pos state
              ~new_node:prev tl
  (* The "run-length"-encoding nature of alignment implies that our edges have
     to link to the next sequence element iff they are consecutive
     (ex. "A..C", "...A..C" ) as opposed to linking back to the reference! *)
  and close_position_loop state ~prev ~next ~allele_node pe lst =
    match test_consecutive_elements pe lst with
    | `Close pos                            ->
        rejoin_after_split pos state ~prev ~next ~new_node:allele_node lst
    | `Continue (new_node_opt, new_pe, lst) ->
        let allele_node =
          match new_node_opt with
          | None    -> allele_node
          | Some nn -> add_allele_edge allele_node nn; nn
        in
        close_position_loop state ~prev ~next ~allele_node new_pe lst
  (* When not in a reference gap *)
  and main_loop state ~prev ~next = function
    | []              -> inv_argf "No End at allele sequence: %s" allele
    | Start p :: _    -> inv_argf "Another start %d in %s allele sequence." p allele
    | End end_pos :: tl  ->
        let prev =
          match split_in ~prev ~next ~visit:add_allele_edge end_pos with
          | `AfterLast p
          | `AtNext (p, _)
          | `InGap (p, _, _) -> p
        in
        add_end state end_pos prev tl
    | Boundary { idx; pos} :: t ->
        let prev, next =
          advance_until_boundary ~prev ~next ~visit:add_allele_edge
            pos idx
        in
        let () = add_allele_edge prev next in
        main_loop state ~prev ~next t
    | Sequence { start; s} :: t ->
        let new_node = G.V.create (N (start, s)) in
        let open_res = split_in ~prev ~next ~visit:add_allele_edge start in begin
        match open_res with
        | `AfterLast prev         ->
            let () = add_allele_edge prev new_node in
            solo_loop state new_node t
        | `InGap (prev, next, _)
        | `AtNext (prev, next)    ->
            let () = add_allele_edge prev new_node in
            let close_pos = start + String.length s in
            close_position_loop ~prev ~next ~allele_node:new_node state (`Sequence close_pos) t
        end
    | Gap {start; length} :: t ->
        let open_res = split_in ~prev ~next ~visit:add_allele_edge start in begin
        match open_res with
        | `AfterLast prev         ->
            solo_loop state next t
        | `InGap (prev, next, _)
        | `AtNext (prev, next)    ->
            let close_pos = start + length in
            close_position_loop ~prev ~next ~allele_node:prev state (`Gap close_pos) t
        end
  in
  start_loop [] alt_lst

module FoldAtSamePosition = struct

  (* TODO: use a real heap/pq ds?
    - The one in Graph doesn't allow you to control not putting in duplicates
  *)
  module NodeQueue =
    Set.Make(struct
      type t = Nodes.t
      let compare = Nodes.compare_by_position_first
    end)

  let add_successors g = G.fold_succ NodeQueue.add g

  let with_start_nodes {g; aindex; bounds } =
    let open Nodes in
    Alleles.Map.fold aindex bounds ~init:NodeQueue.empty
      ~f:(fun q sep_lst allele ->
            List.fold_left sep_lst ~init:q
              ~f:(fun q sep ->
                    NodeQueue.add (S (fst sep.start, allele)) q))

  let after_start_nodes {g; aindex; bounds } =
    let open Nodes in
    Alleles.Map.fold aindex bounds ~init:NodeQueue.empty
      ~f:(fun q sep_lst allele ->
            List.fold_left sep_lst ~init:q
              ~f:(fun q sep ->
                    add_successors g (S (fst sep.start, allele)) q))

  let at_min_position q =
    let rec loop p q acc =
      if q = NodeQueue.empty then
        q, acc
      else
        let me = NodeQueue.min_elt q in
        match acc with
        | [] -> loop (Nodes.position me) (NodeQueue.remove me q) [me]
        | _  -> if Nodes.position me = p then
                  loop p (NodeQueue.remove me q) (me :: acc)
                else
                  q, acc
    in
    loop min_int q []

  let step g q =
    let without_old, amp = at_min_position q in
    let withnew =
      List.fold_left amp ~init:without_old ~f:(fun q n -> add_successors g n q)
    in
    withnew, amp

  let fold_from g q ~f ~init =
    let rec loop a q =
      if q = NodeQueue.empty then
        a
      else
        let nq, amp = step g.g q in
        let na = f a amp in
        loop na nq
    in
    loop init q

  let fold_after_starts g ~f ~init =
    fold_from g (after_start_nodes g) ~f ~init

  let f g ~f ~init =
    fold_from g (with_start_nodes g) ~f ~init

end (* FoldAtSamePosition *)

(** [range g] returns the minimum and maximum alignment position in [g]. *)
let range { aindex; bounds; _ } =
  Alleles.Map.fold aindex bounds ~init:(max_int, min_int)
    ~f:(fun p sep_lst _allele ->
          List.fold_left sep_lst ~init:p ~f:(fun (st, en) sep ->
            (min st (fst sep.start)), (max en sep.end_)))

type by_position =
  | NL of Nodes.t list
  | Redirect of int

let create_by_position gt =
  let st, en = range gt in
  let len = en - st + 1 in
  let arr = Array.make len [] in
  FoldAtSamePosition.(f gt ~init:() ~f:(fun () lst ->
    let p = Nodes.position (List.hd_exn lst) in
    let j = p - st in
    arr.(j) <- lst));
  let prev = ref 0 in
  Array.mapi (fun i nl ->
    match nl with
    | [] -> Redirect !prev
    | ls -> prev := i; NL ls)
    arr

module JoinSameSequencePaths = struct

  (* Alignment and sequence pair set used as queue *)
  module Apsq =
    Set.Make(struct
      type t = alignment_position * sequence
      let compare (a1, s1) (a2, s2) =
        let r = compare_alignment_position a1 a2 in
        if r = 0 then
          compare_sequence s1 s2
        else
          r
    end)

  let peak_min_position q =
    if Apsq.is_empty q then
      None
    else
      Some (fst (Apsq.min_elt q))

  let at_min_position q =
    let rec loop p q acc =
      if Apsq.is_empty q then
        q, acc
      else
        let me = Apsq.min_elt q in
        match acc with
        | [] -> loop (fst me) (Apsq.remove me q) [me]
        | _  -> if fst me = p then
                  loop p (Apsq.remove me q) (me :: acc)
                else
                  q, acc
    in
    loop min_int q []

  let rec add_node_successors_only g v q =
    let open Nodes in
    match v with
    | N (a, s) -> Apsq.add (a, s) q
    | E _      -> q
    | S _
    | B _      -> G.fold_succ (add_node_successors_only g) g v q

  let after_starts {g; aindex; bounds} =
    let open Nodes in
    let add_successors = G.fold_succ (add_node_successors_only g) g in
    Alleles.Map.fold aindex bounds ~init:Apsq.empty
      ~f:(fun q sep_lst allele ->
            List.fold_left sep_lst ~init:q
              ~f:(fun q sep ->
                    add_successors (S (fst sep.start, allele)) q))

  let do_it ({g; aindex; _ } as gg) =
    let open Nodes in
    let add_successors = G.fold_succ (add_node_successors_only g) g in
    let qstart = after_starts gg in
    let unite_edges pv nv e =
      try
        let ecur = G.find_edge g pv nv in
        let into = G.E.label ecur in
        Alleles.Set.unite ~into e;
      with Not_found ->
          G.add_edge_e g (G.E.create pv e nv)
    in
    let split_and_rejoin ~index q p s =
      let node = N (p, s) in
      let pr = G.pred_e g node in
      let su = G.succ_e g node in
      G.remove_vertex g node;
      let fs, sn = String.split_at s ~index in
      let p1 = p + index in
      let v1 = N (p, fs) in
      if not (G.mem_vertex g v1) then G.add_vertex g v1;
      let s_inter =
        List.fold_left pr ~init:(A.Set.init aindex)
          ~f:(fun bta (p, bt, _) ->
                unite_edges p v1 bt;
                A.Set.union bt bta)
      in
      let v2 = N (p1, sn) in
      if not (G.mem_vertex g v2) then G.add_vertex g v2;
      unite_edges v1 v2 s_inter;
      List.iter su ~f:(fun (_, e, s) -> unite_edges v2 s e);
      Apsq.add (p1, sn) q
    in
    (* assume the list isn't empty *)
    let find_higest_index ~must_split lst =
      let init = Option.value must_split ~default:max_int in
      let max_compare_length =
        List.fold_left lst ~init ~f:(fun l (_p, s) ->
          min l (String.length s))
      in
      let arr = [| 0; 0; 0; 0 |] in
      let rec loop index =
        if index >= max_compare_length then
          index
        else begin
          for i = 0 to 3 do arr.(i) <- 0 done;
          List.iter lst ~f:(fun (_p, s) ->
            let c = String.get_exn s ~index in
            let j = Kmer_to_int.char_to_int c in
            arr.(j) <- arr.(j) + 1);
          match arr with
          | [| n; 0; 0; 0 |] when n >= 1 -> loop (index + 1)
          | [| 0; n; 0; 0 |] when n >= 1 -> loop (index + 1)
          | [| 0; 0; n; 0 |] when n >= 1 -> loop (index + 1)
          | [| 0; 0; 0; n |] when n >= 1 -> loop (index + 1)
          | _                            -> index + 1
        end
      in
      loop 0
    in
    let flatten ~next_pos q = function
      | []                -> q
      | (p, s) :: []      -> add_successors (N (p, s)) q
      | (p, _) :: _ as ls ->
          let must_split = Option.map ~f:(fun pn -> pn - p) next_pos in
          let split_index = find_higest_index ~must_split ls in
          List.fold_left ls ~init:q ~f:(fun q (p, s) ->
            if String.length s <= split_index then
              add_successors (N (p, s)) q
            else
              split_and_rejoin ~index:split_index q p s)
    in
    let rec loop q =
      if q = Apsq.empty then
        ()
      else
        let nq, amp = at_min_position q in
        let next_pos = peak_min_position nq in
        let nq = flatten ~next_pos nq amp in
        loop nq
    in
    loop qstart

end (* JoinSameSequencePaths *)

type construct_which_args =
  | NumberOfAlts of int
  | SpecificAlleles of string list

let construct_which_args_to_string = function
  | NumberOfAlts n    -> sprintf "N%d" n
  | SpecificAlleles l -> sprintf "S%s" (String.concat ~sep:"_" l)

let construct_from_parsed ?which ?(join_same_sequence=true) r =
  let open Mas_parser in
  let { reference; ref_elems; alt_elems} = r in
  let alt_elems = List.sort ~cmp:(fun (n1, _) (n2, _) -> A.compare n1 n2) alt_elems in
  let alt_alleles =
    match which with
    | None ->
        alt_elems
    | Some (NumberOfAlts num_alt_to_add) ->
        List.take alt_elems num_alt_to_add
    | Some (SpecificAlleles alst)        ->
        let assoc_wrap name =
          if name = reference then None else
            try Some (name, List.assoc name alt_elems)
            with Not_found ->
              eprintf "Ignoring requested allele %s in graph construction."
                name;
              None
        in
        List.filter_map alst ~f:assoc_wrap
  in
  let num_alleles = List.length alt_alleles in
  let ref_length = List.length ref_elems in
  let g = G.create ~size:(ref_length * num_alleles) () in
  let aindex = A.index (reference :: List.map ~f:fst alt_alleles) in
  let refs_start_ends = add_reference_elems g aindex reference ref_elems in
  let fs_ls_st_assoc = reference_starts_and_ends refs_start_ends in
  let start_and_stop_assoc =
    List.fold_left alt_alleles ~init:[ reference, refs_start_ends]
      ~f:(fun acc (allele, lst) ->
            let start_and_stops = add_non_ref g reference aindex fs_ls_st_assoc allele lst in
            (allele, start_and_stops) :: acc)
  in
  let bounds =
    A.Map.init aindex (fun allele -> List.rev (List.assoc allele start_and_stop_assoc))
  in
  let gg = { g; aindex; bounds } in
  if join_same_sequence then JoinSameSequencePaths.do_it gg;
  gg

let construct_from_file ~join_same_sequence ?which file =
  construct_from_parsed ~join_same_sequence ?which (Mas_parser.from_file file)

(* More powerful accessors *)
let all_bounds { aindex; bounds; _} allele =
  Alleles.Map.get aindex bounds allele

let find_bound g allele ~pos =
  all_bounds g allele
  |> List.find ~f:(fun sep -> (fst sep.start) <= pos && pos <= sep.end_)
  |> Option.value_map ~default:(error "%d is not in any bounds" pos)
        ~f:(fun s -> Ok s)

(* find a vertex that is at the specified alignment position and if the node starts
   at that position (precise) or the position is inside the node, only relevant to
   sequence nodes N or Boundary positions.

   TODO: This method is O(n) ... need better, really fold_along_allele is not
         good enough. *)
let find_position ?(next_after=false) t allele ~pos =
  let open Nodes in
  let next_after o v = if next_after then Some (v, false) else o in
  find_bound t allele ~pos >>= fun bound ->
    let start = S (fst bound.start, allele) in
    fold_along_allele t.g t.aindex allele ~start ~init:None
      ~f:(fun o v ->
            match v with
            | S (p, _) when p <= pos                   -> o, `Continue
            | S (p, _) (*   p > pos *)                 -> next_after o v, `Stop
            | E p                                      -> next_after o v, `Stop
            | B (p, _) when p = pos                    -> Some (v, true), `Stop
            | B (p, _) when p > pos                    -> next_after o v, `Stop
            | B (p, _) (*   p < pos*)                  -> o, `Continue
            | N (p, s) when p = pos                    -> Some (v, true), `Stop
            | N (p, s) when inside_seq p s ~pos        -> Some (v, false), `Stop
            | N (p, s) when p < pos                    -> o, `Continue
            | N (p, s)  (* p + String.length s > pos*) -> next_after o v, `Stop)
    |> Option.value_map ~default:(error "%d in a gap" pos)
          ~f:(fun x -> Ok x)

let parse_start_arg g allele =
  let open Nodes in function
  | Some (`Node s)    ->
      if G.mem_vertex g.g s then
        Ok [ s ]
      else
        error "%s vertex not in graph" (vertex_name s)
  | Some (`AtPos p)   ->
      find_position g allele p >>= fun (v, precise) ->
        if precise then
          Ok [v]
        else
          error "Couldn't find precise starting pos %d" p
  | Some (`AtNext p)  ->
      find_position g allele p >>= fun (v, _) ->
        Ok [v]
  | None              ->
      match A.Map.get g.aindex g.bounds allele with
      | []  -> error "Allele %s not found in graph!" allele
      | spl -> Ok (List.map spl ~f:(fun sep ->
                        Nodes.S (fst sep.start, allele)))

let parse_stop_arg =
  let stop_if b = if b then `Stop else `Continue in
  let open Nodes in function
  | None             -> (fun _ -> `Continue)                  , (fun x -> x)
  | Some (`AtPos p)  -> (fun n -> stop_if (position n >= p))  , (fun x -> x)
  | Some (`Length n) -> let r = ref 0 in
                        (function
                          | S _ | E _ | B _ -> `Continue
                          | N (_, s) ->
                              r := !r + String.length s;
                              stop_if (!r >= n))              , String.take ~index:n

(** Accessors. *)
let sequence ?start ?stop ({g; aindex; bounds } as gt) allele =
  let open Nodes in
  parse_start_arg gt allele start
  >>= fun start ->
    let stop, pp = parse_stop_arg stop in
    List.fold_left start ~init:[] ~f:(fun acc start ->
      fold_along_allele g aindex allele ~start ~init:acc
        ~f:(fun clst node ->
              match node with
              | N (_, s)          -> (s :: clst, stop node)
              | S _ | E _ | B _   -> (clst, stop node)))
    |> List.rev
    |> String.concat
    |> pp
    |> fun s -> Ok s

let alleles_with_data { aindex; bounds; _} ~pos =
  let es = Alleles.Set.init aindex in
  Alleles.Map.iter aindex bounds ~f:(fun sep_lst allele ->
    List.iter sep_lst ~f:(fun sep ->
      if (fst sep.start) <= pos && pos < sep.end_ then
        Alleles.Set.set aindex es allele
      (* No need to clear! *)));
  es

(* This method is super awkward, since it is mirroring the
  gap searching logic of Adjacents, but not as carefully/exhaustively. *)
let search_through_gap g node ~pos =
  let preds =
    G.fold_pred_e (fun (pn, e, _) l -> (Nodes.position pn, pn, e) :: l) g node []
    |> List.sort ~cmp:compare (* should be precise about comparing by position. *)
  in
  let back_look =
    List.find_map preds ~f:(fun (p, n, e) ->
      if Nodes.inside pos n then Some (n, e) else None)
  in
  match back_look with
  | Some v -> Ok v
  | None   -> (* try looking forward again! *)
      let frds =
        List.fold_left preds ~init:[] ~f:(fun acc (_, n, _) ->
          G.fold_succ_e (fun (_, e, n) l -> (Nodes.position n, n, e) :: l)
            g n [])
        |> List.sort ~cmp:compare
      in
      let forward_look =
        List.find_map frds ~f:(fun (p, n, e) ->
          if Nodes.inside pos n then Some (n, e) else None)
      in
      match forward_look with
      | Some v -> Ok v
      | None   -> error "Couldn't work through gap before %s for %d"
                    (Nodes.vertex_name node) pos

let find_root_position ({g; aindex; _} as gt) ~pos =
  let all_edges = alleles_with_data gt ~pos in
  let root_allele = Alleles.Set.min_elt aindex all_edges in
  find_position ~next_after:true gt root_allele ~pos >>=
    fun ((rootn, _precise) as rp) ->
      if Nodes.position rootn > pos then begin  (* In a gap, work backwards! *)
        search_through_gap g rootn ~pos >>= fun (n, e) ->
          let new_root_allele = Alleles.Set.min_elt aindex e in
          Ok (new_root_allele, all_edges, (n, (Nodes.position n = pos)))
      end else
        Ok (root_allele, all_edges, rp)

module NodeSet = MoreLabels.Set.Make
  (struct
    type t = Nodes.t
    let compare = Nodes.compare
  end)

module EdgeNodeSet = MoreLabels.Set.Make
  (struct
    (* edges first since these edges point into the respective node. *)
    type t = Edges.t * Nodes.t

    let compare (e1, n1) (e2, n2) =
      let r = Nodes.compare n1 n2 in
      if r = 0 then Edges.compare e1 e2 else r
  end)

let node_set_to_string s =
  NodeSet.fold ~f:(fun n a -> Nodes.vertex_name n :: a) ~init:[] s
  |> String.concat ~sep:"; "
  |> sprintf "{%s}"

let edge_node_set_to_string aindex s =
  EdgeNodeSet.fold ~f:(fun (e, n) a ->
    (sprintf "(%s -> %s)"
      (Alleles.Set.to_human_readable aindex ~compress:true e)
      (Nodes.vertex_name n)) :: a) ~init:[] s
  |> String.concat ~sep:"; "
  |> sprintf "{%s}"

let edge_node_set_to_table aindex s =
  EdgeNodeSet.fold ~f:(fun p l -> p :: l) ~init:[] s
  |> List.sort ~cmp:(fun (_,n1) (_,n2) -> Nodes.compare n1 n2)
  |> List.map ~f:(fun (e, n) ->
      sprintf "%s <- %s"
        (Nodes.vertex_name n)
        (Alleles.Set.to_human_readable aindex ~compress:true e))
  |> String.concat ~sep:"\n"
  |> sprintf "%s"

let debug_ref = ref false

(* Methods for finding adjacent nodes/edges combinations.:
   Nodes with the same (or greater; due to gaps) alignment position.

   Aside from checking the bounds and looking for Boundary positions,
   there is no way of knowing when we have found all adjacents. These
   algorithms expand a set of successively seen nodes at progressively
   farther distance (measured by edges) from the root node. At each
   step they recurse down and explore new adjacents. The two main methods

   {until} and {check_by_levels} provide a fold operation over these
   adjacents (via ~f and ~init) as they are discovered and also returns:
   1. A EdgeNodeSet of actual adjacents. adjacent nodes can have multiple
      edges leading into them.
   2. The final accumulator value.
   3. A stack of encountered nodes (probably not useful). *)
module Adjacents = struct

  (* [add_if_new cur node sibs] Add [node] to [kids] if it isn't in [cur]rent.
     Although [kids] and [cur] may represent nodes at different alignment
     position, to prevent traversing/recursing down the same paths as we
     discover new kids, we keep track of two sets.

     (check) + (add) -> O(log n) + O(log n) = O(2 log n
     as opposed to O(log n) for just adding but then we redo lots (how much?)
     work and can't add the is_empty stop condition in [down].  *)
  let add_if_new ~cur n kids =
    if NodeSet.mem n cur then kids else NodeSet.add n kids

  let siblings_and_adjacents pos ~if_new g ~new_nodes ~cur ~adjacents acc =
    let add ((_pn, _el, n) as e) (kids, adjs, acc) =
      if Nodes.position n >= pos then
        let nadjs, nacc = if_new e (adjs, acc) in
        kids, nadjs, nacc
      else
        let nkids = add_if_new ~cur n kids in
        nkids, adjs, acc
    in
    let init = NodeSet.empty, adjacents, acc in
    NodeSet.fold new_nodes ~f:(G.fold_succ_e add g) ~init

  let rec down if_new g pos acc ~adjacents ~new_nodes cur =
    let newer_nodes, nadjacents, nacc =
      siblings_and_adjacents pos ~if_new g ~new_nodes ~cur ~adjacents acc
    in
    let new_cur = NodeSet.union cur new_nodes in
    if NodeSet.is_empty newer_nodes then
      (* no new nodes don't recurse! *)
      nadjacents, nacc, new_cur
    else
      down if_new g pos acc ~adjacents:nadjacents ~new_nodes:newer_nodes new_cur

  let look_above g cur =
    NodeSet.fold cur ~f:(G.fold_pred (add_if_new ~cur) g) ~init:NodeSet.empty

  (* A general combination of [up] and [down] that is parameterized
     [search] that should tell us when to stop recursing. *)
  let up_and ?max_height ~init ~if_new ~down g ~pos node =
    let rec up i adjacents acc ~new_nodes cur =
      match max_height with
      | Some h when i >= h  -> adjacents, acc, NodeSet.union new_nodes cur
      | None | Some _       ->
          match down acc ~adjacents ~new_nodes cur with
          | `Stop t         -> t
          | `Continue (nadjacents, nacc, ncur) ->
              let newer_nodes = look_above g new_nodes in
              if !debug_ref then
                eprintf "Adding new newer_nodes: %s\n from new_nodes: %s\n"
                  (node_set_to_string newer_nodes) (node_set_to_string new_nodes);
              up (i + 1) nadjacents nacc ~new_nodes:newer_nodes ncur
    in
    let adj_strt, nacc = G.fold_pred_e if_new g node (EdgeNodeSet.empty, init) in
    let new_nodes = G.fold_pred NodeSet.add g node NodeSet.empty in
    let cur = NodeSet.singleton node in
    up 0 adj_strt nacc ~new_nodes cur

  (* A more general method that checks whether to continue after each new
     adjacent. Since we throw an exception to terminate early, the search
     stack isn't correct. *)
  let until (type a) ?max_height ~f ~init g node =
    let module M = struct exception F of a end in
    let if_new (_, e, n) ((adjacents, acc) as s) =
      let en = e, n in
      if EdgeNodeSet.mem en adjacents then s else
        match f e n acc with
        | `Stop r     -> raise (M.F r)
        | `Continue r -> EdgeNodeSet.add en adjacents, r
    in
    let pos = Nodes.position node in
    let downc = down if_new g pos  in
    let down acc ~adjacents ~new_nodes cur =
      try `Continue (downc acc ~adjacents ~new_nodes cur)
      with M.F r -> `Stop (adjacents, r, (NodeSet.union new_nodes cur))
    in
    up_and ?max_height ~init ~if_new ~down g ~pos node

  (* A less general method that requires an extra predicate function to check
     the stopping condition. The advantage is that we check less frequently and
     probably when it matters: when we increase the level of how far back in
     the graph we look for adjacents. *)
  let check_by_levels ?max_height ~f ~stop ~init g node =
    let if_new (pn, e, n) ((adjacents, acc) as s) =
      if !debug_ref then
        eprintf "if_new check of %s -> %s\n"
          (Nodes.vertex_name pn) (Nodes.vertex_name n);
      let en = e, n in
      if EdgeNodeSet.mem en adjacents then s else
        EdgeNodeSet.add en adjacents, (f e n acc)
    in
    let pos = Nodes.position node in
    let downc = down if_new g pos in
    let down acc ~adjacents ~new_nodes cur =
      let (nadjacents, nacc, ptl) as state =
        downc acc ~adjacents ~new_nodes cur
      in
      if stop nacc then
        `Stop (nadjacents, nacc, (NodeSet.union new_nodes cur))
      else
        `Continue state
    in
    up_and ?max_height ~init ~if_new ~down g ~pos node

end (* Adjacents *)

(* At or past *)
let sequence_nodes_at ?(max_height=10) ({g; aindex; _} as gt)  ~pos =
  find_root_position gt ~pos >>= fun (_root_allele, all_edges, (rootn, _precise)) ->
    let stop es_acc =
      if es_acc = all_edges then true else
        begin
          if !debug_ref then
            eprintf "Still missing %s\n"
              (Alleles.Set.to_human_readable aindex (Alleles.Set.diff all_edges es_acc));
          false
        end
    in
    let f edge node edge_set =
      if !debug_ref then
        eprintf "Adding %s <- %s\n"
          (Nodes.vertex_name node)
          (Alleles.Set.to_human_readable aindex edge);
      Alleles.Set.union edge edge_set
    in
    let init = Alleles.Set.init aindex in
    (*let adj, _es, _stack = *) Ok ( Adjacents.check_by_levels ~max_height ~init ~stop g rootn ~f)
    (*Ok adj*)

