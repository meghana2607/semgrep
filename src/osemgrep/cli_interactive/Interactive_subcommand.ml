(*****************************************************************************)
(* Prelude *)
(*****************************************************************************)
(*
   Parse a semgrep-interactive command, execute it and exit.

*)

open Notty
open Notty_unix

(*****************************************************************************)
(* Types and constants *)
(*****************************************************************************)

type command = Exit | Pat of Xpattern.t * bool | Any | All

type interactive_pat =
  | IPat of Xpattern.t * bool
  | IAll of interactive_pat list
  | IAny of interactive_pat list

type matches_by_file = {
  file : string;
  matches : Pattern_match.t Pointed_zipper.t;
      (** A zipper, because we want to be able to go back and forth
        through the matches in the file.
        Fortunately, a regular zipper is equivalent to a pointed
        zipper with a frame size of 1.
      *)
}

(* The type of the state for the interactive loop.
   This is the information we need to carry in between every key press,
   and whenever we need to redraw the canvas.
*)
type state = {
  xlang : Xlang.t;
  xtargets : Xtarget.t list;
  file_zipper : matches_by_file Pointed_zipper.t;
  cur_line_rev : char list;
      (** The current line that we are reading in, which is not yet
        finished.
        It's in reverse because we're consing on to the front.
      *)
  pat : interactive_pat option;
  mode : bool;  (** True if `All`, false if `Any`
      *)
  term : Notty_unix.Term.t;
}

(* Arbitrarily, let's just set the width of files to 40 chars. *)
let files_width = 40

(* color settings *)
let light_green = A.rgb_888 ~r:77 ~g:255 ~b:175
let neutral_yellow = A.rgb_888 ~r:255 ~g:255 ~b:161
let bg_file_selected = A.(bg (gray 5))
let bg_match = A.(bg (gray 5))
let bg_match_position = A.(bg light_green ++ fg (gray 3))
let fg_line_num = A.(fg neutral_yellow)

(*****************************************************************************)
(* Helpers *)
(*****************************************************************************)

let files_height_of_term term = snd (Term.size term) - 3

let empty xlang xtargets term =
  {
    xlang;
    xtargets;
    file_zipper = Pointed_zipper.empty_with_max_len (files_height_of_term term);
    cur_line_rev = [];
    pat = None;
    mode = true;
    term;
  }

let get_current_line state =
  Common2.string_of_chars (List.rev state.cur_line_rev)

let fk = Tok.unsafe_fake_tok ""

let rec translate_formula = function
  | IPat (pat, true) -> Rule.P pat
  | IPat (pat, false) -> Rule.Not (fk, P pat)
  | IAll ipats ->
      Rule.And
        ( fk,
          {
            conjuncts = Common.map translate_formula ipats;
            conditions = [];
            focus = [];
          } )
  | IAny ipats -> Rule.Or (fk, Common.map translate_formula ipats)

let mk_fake_rule lang formula =
  {
    Rule.id = ("-i", fk);
    mode = `Search formula;
    (* alt: could put xpat.pstr for the message *)
    message = "";
    severity = Error;
    languages = lang;
    options = None;
    equivalences = None;
    fix = None;
    fix_regexp = None;
    paths = None;
    metadata = None;
  }

let matches_of_new_ipat new_ipat state =
  let rule_formula = translate_formula new_ipat in
  let fake_rule = mk_fake_rule state.xlang rule_formula in
  let hook _s (_m : Pattern_match.t) = () in
  let xconf =
    {
      Match_env.config = Rule_options.default_config;
      equivs = [];
      nested_formula = false;
      matching_explanations = false;
      filter_irrelevant_rules = false;
    }
  in
  let res : Report.rule_profiling Report.match_result list =
    state.xtargets
    |> Common.map (fun xtarget ->
           let results =
             Match_search_mode.check_rule fake_rule hook xconf xtarget
           in
           results)
  in
  let res_by_file =
    res
    |> List.concat_map (fun ({ matches; _ } : _ Report.match_result) ->
           Common.map (fun (m : Pattern_match.t) -> (m.file, m)) matches)
    |> Common2.group_assoc_bykey_eff
    (* A pointed zipper with a frame size of 1 is the same as a regular
       zipper.
    *)
    |> Common.map (fun (file, pms) ->
           let sorted_pms =
             List.sort
               (fun { Pattern_match.range_loc = l1, _; _ }
                    { Pattern_match.range_loc = l2, _; _ } ->
                 Int.compare l1.pos.charpos l2.pos.charpos)
               pms
           in
           { file; matches = Pointed_zipper.of_list 1 sorted_pms })
    |> List.sort (fun { file = k1; _ } { file = k2; _ } -> String.compare k1 k2)
  in
  Pointed_zipper.of_list (files_height_of_term state.term) res_by_file

let safe_subtract x y =
  let res = x - y in
  if res < 0 then 0 else res

(*****************************************************************************)
(* User Interface *)
(*****************************************************************************)

(* Given the bounds of a highlighted range, does this index
   fall in or out of the highlighted range?
*)
let placement_wrt_bound (lb, rb) idx =
  match (lb, rb) with
  | None, None -> Common.Middle3 ()
  | Some lb, _ when idx < lb -> Left3 ()
  | _, Some rb when idx >= rb -> Right3 ()
  | __else__ -> Middle3 ()

(* Given the range of a match, we want to split a given line
 * into things that are in the match, or are not.
 *)
let split_line (t1 : Tok.location) (t2 : Tok.location) (row, line) =
  let end_line, end_col, _ = Tok.end_pos_of_loc t2 in
  if row < t1.pos.line then (line, "", "")
  else if row > t2.pos.line then (line, "", "")
  else
    let lb = if row = t1.pos.line then Some t1.pos.column else None in
    let rb = if row = end_line then Some end_col else None in
    let l_rev, m_rev, r_rev, _ =
      String.fold_left
        (fun (l, m, r, i) c ->
          match placement_wrt_bound (lb, rb) i with
          | Common.Left3 _ -> (c :: l, m, r, i + 1)
          | Middle3 _ -> (l, c :: m, r, i + 1)
          | Right3 _ -> (l, m, c :: r, i + 1))
        ([], [], [], 0) line
    in
    ( Common2.string_of_chars (List.rev l_rev),
      Common2.string_of_chars (List.rev m_rev),
      Common2.string_of_chars (List.rev r_rev) )

let preview_of_match { Pattern_match.range_loc = t1, t2; _ } file state =
  let lines = Common2.cat file in
  let start_line = t1.pos.line in
  let end_line = t2.pos.line in
  let max_height = files_height_of_term state.term in
  let match_height = end_line - start_line in
  (* We want the appropriate amount of lines that will fit within
     our terminal window.
     We also want the match to be relatively centered, however.
     Fortunately, the precise math doesn't matter too much. We
     take the height of the match and try to equivalently
     pad it on both sides with other lines.
     TODO(brandon): cases for if the match is too close to the top
     or bottom of the file
  *)
  let preview_start, preview_end =
    if match_height <= max_height then
      (* if this fits within our window *)
      let extend_before = (max_height - match_height) / 2 in
      let start = safe_subtract start_line extend_before in
      (start, start + max_height)
    else (start_line, start_line + max_height)
  in
  let line_num_imgs, line_imgs =
    lines
    (* Row is 1-indexed *)
    |> Common.mapi (fun idx x -> (idx + 1, x))
    (* Get only the lines that we care about (the ones in the preview) *)
    |> Common.map_filter (fun (idx, line) ->
           if preview_start <= idx && idx < preview_end then
             Some (idx, split_line t1 t2 (idx, line))
           else None)
    (* Turn line numbers and the line contents to images *)
    |> Common.map (fun (idx, (l, m, r)) ->
           ( I.(string fg_line_num (Int.to_string idx)),
             I.(
               string A.empty l
               (* alt: A.(bg (rgb_888 ~r:255 ~g:255 ~b:194)) *)
               <|> string A.(st bold ++ bg_match) m
               <|> string A.empty r) ))
    |> Common2.unzip
  in
  (* Right-align the images and pad on the right by 1 *)
  let line_num_imgs_aligned_and_padded =
    let max_line_num_len =
      line_num_imgs
      |> Common.map (fun line_num_img -> I.width line_num_img)
      |> List.fold_left Int.max 0
    in
    line_num_imgs
    |> Common.map (fun line_num_img ->
           I.hsnap ~align:`Right max_line_num_len line_num_img)
    |> I.vcat |> I.hpad 0 1
  in
  (* Put the line numbers and contents together! *)
  I.(line_num_imgs_aligned_and_padded <|> vcat line_imgs)

let render_screen state =
  let w, _h = Term.size state.term in
  (* Minus two, because one for the line, and one for
     the input line.
  *)
  let lines_of_files = files_height_of_term state.term in
  let lines_to_pad_below_to_reach l n =
    if List.length l >= n then 0 else n - List.length l
  in
  let files =
    Pointed_zipper.take lines_of_files state.file_zipper
    |> Common.mapi (fun idx { file; _ } ->
           if idx = Pointed_zipper.relative_position state.file_zipper then
             I.string A.(fg (gray 19) ++ st bold ++ bg_file_selected) file
           else I.string (A.fg (A.gray 16)) file)
  in
  let preview =
    if Pointed_zipper.is_empty state.file_zipper then
      I.string A.empty "preview unavailable (no matches)"
    else
      let { file; matches = matches_zipper } =
        Pointed_zipper.get_current state.file_zipper
      in
      (* 1 indexed *)
      let match_idx = Pointed_zipper.absolute_position matches_zipper + 1 in
      let total_matches = Pointed_zipper.length matches_zipper in
      let match_position_img =
        if total_matches = 1 then I.void 0 0
        else
          I.string bg_match_position
            (Common.spf "%d/%d" match_idx total_matches)
          |> I.hsnap ~align:`Right (w - files_width - 1)
      in
      let pm = Pointed_zipper.get_current matches_zipper in
      I.(match_position_img </> preview_of_match pm file state)
  in
  let vertical_bar = I.char A.empty '|' 1 (files_height_of_term state.term) in
  let horizontal_bar = String.make w '-' |> I.string (A.fg (A.gray 12)) in
  let prompt =
    I.(string (A.fg A.cyan) "> " <|> string A.empty (get_current_line state))
  in
  let lowerbar = I.(string (A.fg A.green) "Semgrep Interactive Mode") in
  (* The format of the Interactive Mode UI is:
   *
   * files files vertical bar preview preview preview
   * files files vertical bar preview preview preview
   * files files vertical bar preview preview preview
   * files files vertical bar preview preview preview
   * files files vertical bar preview preview preview
   * horizontal bar   horizontal bar   horizontal bar
   * prompt prompt prompt prompt prompt prompt prompt
   * lower bar lower bar lower bar lower bar lower bar
   *)
  I.(
    files |> I.vcat
    (* THINK: unnecessary? *)
    |> I.vpad 0 (lines_to_pad_below_to_reach files lines_of_files)
    |> (fun img -> I.hcrop 0 (I.width img - files_width) img)
    <|> vertical_bar <|> preview <-> horizontal_bar <-> prompt <-> lowerbar)

(*****************************************************************************)
(* Commands *)
(*****************************************************************************)

let parse_command ({ xlang; _ } as state : state) =
  let s = get_current_line state in
  match s with
  | "exit" -> Exit
  | "any" -> Any
  | "all" -> All
  | _ when String.starts_with ~prefix:"not " s ->
      let s = Str.string_after s 4 in
      (* TODO: error handle *)
      let lang = Xlang.to_lang_exn xlang in
      let lpat = lazy (Parse_pattern.parse_pattern lang s) in
      Pat
        ( Xpattern.mk_xpat
            (Xpattern.Sem (lpat, lang))
            (s, Tok.unsafe_fake_tok ""),
          false )
  | _else_ ->
      (* TODO: error handle *)
      let lang = Xlang.to_lang_exn xlang in
      let lpat = lazy (Parse_pattern.parse_pattern lang s) in
      Pat
        ( Xpattern.mk_xpat
            (Xpattern.Sem (lpat, lang))
            (s, Tok.unsafe_fake_tok ""),
          true )

let execute_command (state : state) =
  let cmd = parse_command state in
  let handle_pat (pat, b) =
    let new_pat = IPat (pat, b) in
    match (state.pat, state.mode) with
    | None, _ -> new_pat
    | Some (IAll pats), true -> IAll (new_pat :: pats)
    | Some (IAny pats), false -> IAny (new_pat :: pats)
    | Some pat, true -> IAny [ new_pat; pat ]
    | Some pat, false -> IAll [ new_pat; pat ]
  in
  let state =
    match cmd with
    | Exit -> failwith "bye bye"
    | All -> { state with mode = true }
    | Any -> { state with mode = false }
    | Pat (pat, b) ->
        let new_ipat = handle_pat (pat, b) in
        let file_zipper = matches_of_new_ipat new_ipat state in
        { state with file_zipper; pat = Some new_ipat }
  in
  (* Remember to reset the current line after executing a command. *)
  { state with cur_line_rev = [] }

(*****************************************************************************)
(* Interactive loop *)
(*****************************************************************************)

let interactive_loop xlang xtargets =
  let rec update (t : Term.t) state =
    Term.image t (render_screen state);
    loop t state
  and loop t state =
    match Term.event t with
    | `Key (`Enter, _) ->
        let state = execute_command state in
        update t state
    | `Key (`Backspace, _) -> (
        match state.cur_line_rev with
        | [] -> loop t state
        | _ :: cs -> update t { state with cur_line_rev = cs })
    | `Key (`Arrow `Left, _) ->
        update t
          {
            state with
            file_zipper =
              Pointed_zipper.map_current
                (fun { file; matches = mz } ->
                  { file; matches = Pointed_zipper.move_left mz })
                state.file_zipper;
          }
    | `Key (`Arrow `Right, _) ->
        update t
          {
            state with
            file_zipper =
              Pointed_zipper.map_current
                (fun { file; matches = mz } ->
                  { file; matches = Pointed_zipper.move_right mz })
                state.file_zipper;
          }
    | `Key (`Arrow `Up, _) ->
        update t
          {
            state with
            file_zipper = Pointed_zipper.move_left state.file_zipper;
          }
    | `Key (`Arrow `Down, _) ->
        update t
          {
            state with
            file_zipper = Pointed_zipper.move_right state.file_zipper;
          }
    | `Key (`ASCII c, _) ->
        update t { state with cur_line_rev = c :: state.cur_line_rev }
    | `Resize _ -> update t state
    | __else__ -> loop t state
  in
  let t = Term.create () in
  Common.finalize
    (fun () ->
      let state = empty xlang xtargets t in
      (* TODO: change *)
      if true then update t state)
    (fun () -> Term.release t)

(*****************************************************************************)
(* Main logic *)
(*****************************************************************************)

(* All the business logic after command-line parsing. Return the desired
   exit code. *)
let run (conf : Interactive_CLI.conf) : Exit_code.t =
  CLI_common.setup_logging ~force_color:false ~level:conf.logging_level;
  let targets, _skipped =
    Find_targets.get_targets conf.targeting_conf conf.target_roots
  in
  (* TODO: support generic and regex patterns as well. See code in Deep.
   * Just use Parse_rule.parse_xpattern xlang (str, fk)
   *)
  let xlang = Xlang.L (conf.lang, []) in
  let targets =
    targets |> List.filter (Filter_target.filter_target_for_xlang xlang)
  in

  let config = Core_runner.runner_config_of_conf conf.core_runner_conf in
  let config = { config with roots = conf.target_roots; lang = Some xlang } in
  let xtargets =
    targets |> Common.map Fpath.to_string
    |> Common.map (Run_semgrep.xtarget_of_file config xlang)
  in
  interactive_loop xlang xtargets;
  Exit_code.ok

(*****************************************************************************)
(* Entry point *)
(*****************************************************************************)

let main (argv : string array) : Exit_code.t =
  let conf = Interactive_CLI.parse_argv argv in
  run conf