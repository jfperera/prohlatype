(* Tests that the merging produces sensible results. *)
open Common
open Util

let to_input prefix = function
  | `Merge    -> Ref_graph.MergeFromPrefix (to_merge_prefix prefix, Distances.Trie)
  | `Genetic  -> Ref_graph.AlignmentFile (to_alignment_file (prefix ^ "_gen"))
  | `Nuclear  -> Ref_graph.AlignmentFile (to_alignment_file (prefix ^ "_nuc"))

let load prefix t =
  Cache.(graph (graph_args ~input:(to_input prefix t) ()))

let split_into_xons = String.split ~on:(`Character '|')

let list_zip = List.map2 ~f:(fun a b -> (a,b))

let test_same ~merged_seq ~genetic_seq (nuc, gen) =
  let labels = sprintf "nuc %s: " nuc , sprintf "gen %s: " gen in
  if merged_seq <> genetic_seq then begin
    let mxs = split_into_xons merged_seq in
    let gxs = split_into_xons genetic_seq in
    let mxs_n = List.length mxs in
    let gxs_n = List.length gxs in
    if mxs_n <> gxs_n then
      error "Merged list for %s doesn't have the same number %d of xon elements as genetic %d %s"
        nuc mxs_n gxs_n gen
    else begin
      list_zip mxs gxs 
      |> list_fold_ok ~init:() ~f:(fun () (m, g) ->
          if m <> g then
            error "while testing %s vs %s\n%s\n" nuc gen
              (manual_comp_display ~labels m g)
          else
              Ok ())
    end
  end else 
    Ok ()

let compare_different_lengths ~s ~b =
  let m = String.length s in
  let n = String.length b in
  if String.compare_substring (s, 0, m) (b, 0, m) = 0 then
    `Left
  else if String.compare_substring (s, 0, m) (b, (n - m), m) = 0 then
    `Right
  else
    `NotEqual

let test_diff ~merged_seq ~genetic_seq ~nuclear_seq (nuc, gen) =
  let desc = sprintf "%s -> %s" nuc gen in
  let labels s = sprintf "%s %s: " s nuc , sprintf "gen %s: " gen in
  if merged_seq = genetic_seq then error "%s merged_seq = genetic_seq" desc else
  if merged_seq = nuclear_seq then error "%s merged_seq = nuclear_seq" desc else
  let mxs = split_into_xons merged_seq in
  let gxs = split_into_xons genetic_seq in
  let nxs = split_into_xons nuclear_seq in
  let mxs_n = List.length mxs in
  let gxs_n = List.length gxs in
  if mxs_n <> gxs_n then
    error "Merged list for %s doesn't have the same number %d of xon elements \
      as genetic %d %s" nuc mxs_n gxs_n gen
  else
    let to_type i = if i mod 2 = 0 then "intron" else "exon" in
    list_zip mxs gxs
    |> list_fold_ok ~init:0 ~f:(fun i (m, g) ->
        if i mod 2 = 0 then (* Intron, compare m to g *)
          if m = g then Ok (i + 1) else begin
            error "while testing %s at %d %s\n%s\n" desc
              i (to_type i) (manual_comp_display ~labels:(labels "mgd") m g)
          end
        else (* Exon, compare to nuclear. *)
          let ex = Option.value (List.nth nxs (i / 2)) ~default:"" in
          if ex = String.empty then
            if m = g then Ok (i + 1) else begin
              error "while testing %s at %d %s with empty nucleic exon \
                comparing vs genetic:\n%s\n" desc i (to_type i)
                (manual_comp_display ~labels:(labels "mgd") m g)
            end
          else if ex = m then
            Ok (i + 1)
          else begin
            match compare_different_lengths ~s:ex ~b:m with
            | `Left     -> printf "%s %d exon matches to the left.\n" desc (i/2); Ok (i+1)
            | `Right    -> printf "%s %d exon matches to the right.\n" desc (i/2); Ok (i+1)
            | `NotEqual -> error "%dth %d exon for %s, doesn't match nuc:\n%s\n" (i / 2) i nuc
                              (manual_comp_display ~labels:(labels "nuc") ex m)
          end)
    >>= fun _n -> Ok ()

let () =
  if !Sys.interactive then () else begin
    let n = Array.length Sys.argv in
    let prefix = if n < 2 then "A" else Sys.argv.(1) in
    let merged_graph = load prefix `Merge in
    let genetic_graph = load prefix `Genetic in
    let nuclear_graph = load prefix `Nuclear in
    List.iter merged_graph.Ref_graph.merge_map ~f:(fun ((nuc, gen) as p) ->
      printf "comparing %s vs %s %!" nuc gen;
      Ref_graph.sequence ~boundaries:true merged_graph nuc >>= begin fun merged_seq ->
        Ref_graph.sequence ~boundaries:true genetic_graph gen >>= fun genetic_seq ->
          if nuc = gen then
            test_same ~merged_seq ~genetic_seq p
          else
            Ref_graph.sequence ~boundaries:true nuclear_graph nuc >>= fun nuclear_seq ->
              test_diff ~merged_seq ~genetic_seq ~nuclear_seq p
      end
      |> function
        | Ok () -> printf "equal\n"
        | Error e -> printf ": %s\n" e; exit 1);
    printf "All tests passed for %s\n" prefix
  end