
open Util

let (//) = Filename.concat
let root_dir = "../foreign/IMGTHLA/alignments"

let cargs ?(file="A_nuc") gi =
  { Cache.alignment_file = (root_dir // file) ^ ".txt"
  ; Cache.which = Some (Ref_graph.NumberOfAlts gi)
  ; Cache.join_same_sequence = true
  }

let all_args ?(file="A_nuc") () =
  { Cache.alignment_file = (root_dir // file) ^ ".txt"
  ; Cache.which = None
  ; Cache.join_same_sequence = true
  }

let g_and_idx ?(cache=true) ?(k=10) ?file ?gi () =
  if cache then
    match gi with
    | None   -> Cache.graph_and_two_index { Cache.k = k; Cache.g = all_args ?file () }
    | Some n -> Cache.graph_and_two_index { Cache.k = k; Cache.g = cargs ?file n }
  else
    match gi with
    | None   -> Cache.graph_and_two_index_no_cache { Cache.k = k; Cache.g = all_args ?file () }
    | Some n -> Cache.graph_and_two_index_no_cache { Cache.k = k; Cache.g = cargs ?file n }

let reads_from_fastq file =
  let ic = open_in file in
  let li = ref [] in
  try
    let rec loop i =
      let line = input_line ic in
      if i mod 4 = 1 then li := line :: !li;
      loop (i + 1)
    in
    loop 0
  with End_of_file ->
    close_in ic;
    !li

let al_to_list idx r =
  Alleles.Map.fold idx ~f:(fun acc c s -> (s, c) :: acc ) ~init:[] r
  |> List.sort ~cmp:compare

let test_case ?compare_pos ~length (g, idx) read =
  let sub_read = String.sub_exn ~index:0 ~length read in
  let pos =
    let open Index in
    match lookup idx sub_read with
    | Error m     -> invalid_argf "error looking up %s in index: %s" sub_read m
    | Ok []       -> invalid_argf "empty position returned looking up %s in index" sub_read
    | Ok (h :: t) ->
          match compare_pos with
          | None   -> h
          | Some p ->
              let dp = p.alignment + p.offset in
              match List.find (h :: t) ~f:(fun pn -> pn.alignment + pn.offset = dp) with
              | None -> invalid_argf "Couldn't find desired pos %d in second graph index! for sub_read: %s" dp sub_read
              | Some p -> p
  in
  let al = Alignment.compute_mismatches g sub_read pos |> unwrap_ok in
  let lal = al_to_list g.Ref_graph.aindex al in
  pos, sub_read, (List.rev lal)

let reads_with_kmers reads_file (g, idx) =
  let reads = reads_from_fastq reads_file in
  let greads =
    List.filter reads ~f:(fun r ->
      match String.index_of_character r 'N' with | Some _ -> false | _ -> true)
    |> Array.of_list
  in
  Array.to_list greads
  |> List.filter_map ~f:(fun s ->
      match Index.lookup idx s with
      | Ok [] | Error _ -> None
      | Ok ls           -> Some s)

let just_lal ?compare_pos ~length gidxp read =
  let pos, _sub_read, lal = test_case ?compare_pos ~length gidxp read in
  pos, lal

let find_bad ?cache ?(length=100) ?(k=10) ?stop reads_file ~file start_size =
  let stop =
    match stop with
    | Some s -> s
    | None -> let gall, _ = g_and_idx ?cache ~file () in
              Alleles.Map.cardinal gall.Ref_graph.bounds
  in
  let gsidx = g_and_idx ?cache ~k ~file ~gi:start_size () in
  let start_reads = reads_with_kmers reads_file gsidx in
  printf "Testing on %d reads\n" (List.length start_reads);
  let start_lals =
    List.map start_reads ~f:(fun read -> read, just_lal ~length gsidx read)
  in
  let diff_lals new_size prev_lals =
    List.fold_left prev_lals ~init:([], [])
      ~f:(fun (nacc, wacc) (read, (compare_pos, prev_lal)) ->
            let gsidx = g_and_idx ?cache ~k ~file ~gi:new_size () in
            let (pos_new, lal_new) = just_lal ~compare_pos ~length gsidx read in
            let diff_opt =
              List.fold_left prev_lal ~init:[] ~f:(fun acc (a, c) ->
                let new_c = List.assoc a lal_new in
                if new_c <> c then (a, c) :: acc else acc)
            in
            match diff_opt with
            | [] -> ((read, (pos_new, lal_new)) :: nacc), wacc
            | dl -> ((read, (pos_new, lal_new)) :: nacc), (read, dl) :: wacc)
  in
  let rec loop prev_size old_lals =
    let gi = prev_size + 1 in
    if gi > stop then
      Ok ("reached stop!")
    else begin
      printf "new gi: %d\n%!" gi;
      match diff_lals gi old_lals with
      | lst, [] -> loop gi lst
      | lst, bd -> Error (gi, bd)
    end
  in
  loop start_size start_lals

let describe_error ?(length=100) ?(k=10) file read gi =
  let gim1 = gi - 1 in
  let cur = !Alignment.debug_ref in
  Alignment.debug_ref := true;
  let (gnm1, i_nm1) as gsidx = g_and_idx ~k ~file ~gi:gim1 () in
  let pnm1, snm1, alnm1 = test_case ~length gsidx read in
  let (gn, i_n) as gsidx2 = g_and_idx ~k ~file ~gi () in
  let pn, sn, aln = test_case ~compare_pos:pnm1 ~length gsidx2 read in
  Alignment.debug_ref := cur;
  (gnm1, i_nm1, pnm1, snm1, alnm1), (gn, i_n, pn, sn, aln)

let manual g idx read =
  Index.lookup idx read >>= function
    | h :: _ -> Ok (h, Alignment.manual_mismatches g read h)
    | []     -> error "read not in index"

let compare_manual g m fm read_len =
  let aindx = g.Ref_graph.aindex in
  Alleles.Map.fold aindx m ~init:[]
    ~f:(fun acc cm allele ->
          let with_all = Alleles.Map.get aindx fm allele in
          match cm, with_all with
          | Ok (`Finished mismatches) , wa when wa = mismatches             ->
            acc
          | Ok (`GoOn (msm, sp))      , wa when wa = msm + (read_len - sp)  ->
            acc
          | Ok cmo                    , wa                                  ->
            (allele, Ok (cmo, wa)) :: acc
          | Error ec                  , wa                                  ->
            (allele, Error (ec, wa)) :: acc)


let compare_reads ?length ?(k=10) ?(drop=0) ?num_comp reads_file ~file =
  let g, idx = g_and_idx ~k ~file () in
  let reads = reads_with_kmers reads_file (g, idx) in
  let reads =
    match num_comp with
    | None -> List.drop reads drop
    | Some n -> List.take (List.drop reads drop) n
  in
  let n = List.length reads in
  let rec over_reads i = function
    | []          -> None
    | read :: tl  ->
      let sub_read, sub_read_len =
        match length with
        | None       -> read, String.length read
        | Some index -> String.take read index, index
      in
      printf "comparing alignments for %d %s" i read;
      match manual g idx sub_read with
      | Error em        ->
          eprintf "Skipping %s because wasn't able to map because of %s\n"
            sub_read em;
          over_reads (i + 1) tl
      | Ok (pos, manm)  ->
          match Alignment.compute_mismatches g sub_read pos with
          | Error mes ->
              eprintf "Wasn't able to compute mismatches for %s at %s because of %s"
                sub_read (Index.show_position pos) mes;
              over_reads (i + 1) tl
          | Ok m2     ->
              match compare_manual g manm m2 (String.length sub_read) with
              | [] -> printf " everything matched!\n%!"; over_reads (i + 1) tl
              | ba -> printf " see differences.\n%!"; Some (read, ba)
  in
  (n, over_reads 0 reads)

let () =
  if !Sys.interactive then () else
    let n = Array.length Sys.argv in
    let reads_file =
      if n <= 1 then
        invalid_argf
          "%s [reads_file] [alignment_file] [length] \
            'G' [graph_size for stability test] or \
            'C' [drop number (optional) for comparison test]"
          Sys.argv.(0)
      else
        Sys.argv.(1)
    in
    let file = if n <= 2 then "A_nuc" else Sys.argv.(2) in
    let length = if n <= 3 then 100 else int_of_string Sys.argv.(3) in
    let test =
      if n <= 4 then `Comparison None else
        begin match Sys.argv.(4) with
        | "G" -> `Stability (int_of_string Sys.argv.(5))
        | "C" -> `Comparison (Some (int_of_string Sys.argv.(5)))
        | x   -> invalid_argf "Unrecognized arg: %s" x
        end
    in
    match test with
    | `Stability start ->
        begin match find_bad reads_file ~length ~file start with
        | Ok s  -> print_endline s
        | Error (bad_size, bad_elems) ->
            printf "found bad alignments %d with graph size: %d and read length: %d\n"
              (List.length bad_elems) bad_size length;
            exit 1
        end
    | `Comparison drop ->
        begin match compare_reads ?drop reads_file ~length ~file with
        | n, None              ->
            printf "all %d reads match!\n" n
        | n, Some (read, blst) ->
            printf "out of %d reads encountered the following errors:\n" n;
            printf "read: %s\n" read;
            List.iter blst ~f:(fun (allele, oe) ->
              printf "\t%s: %s\n" allele
                (match oe with
                 | Ok ((`Finished m), m2)   -> sprintf "Finished %d vs %d" m m2
                 | Ok ((`GoOn (m, p)), m2)  -> sprintf "GoOn %d vs %d, sp: %d" m m2 p
                 | Error (msg, d)           -> sprintf "Error %s %d" msg d));
            exit 1
        end

