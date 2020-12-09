(************************************************************************)
(*         *   The Coq Proof Assistant / The Coq Development Team       *)
(*  v      *         Copyright INRIA, CNRS and contributors             *)
(* <O___,, * (see version control and CREDITS file for authors & dates) *)
(*   \VV/  **************************************************************)
(*    //   *    This file is distributed under the terms of the         *)
(*         *     GNU Lesser General Public License Version 2.1          *)
(*         *     (see LICENSE file for the text of the license)         *)
(************************************************************************)
open Util
open Nativevalues
open Nativecode
open CErrors

(** This file provides facilities to access OCaml compiler and dynamic linker,
used by the native compiler. *)

let get_load_paths =
  ref (fun _ -> anomaly (Pp.str "get_load_paths not initialized.") : unit -> string list)

let open_header = ["Nativevalues";
                   "Nativecode";
                   "Nativelib";
                   "Nativeconv"]
let open_header = List.map mk_open open_header

(* Directory where compiled files are stored *)
let dft_output_dir = ".coq-native"
let output_dir = ref dft_output_dir

(* Extension of generated ml files, stored for debugging purposes *)
let source_ext = ".native"

let ( / ) = Filename.concat

(* Directory for temporary files for the conversion and normalisation
   (as opposed to compiling the library itself, which uses [output_dir]). *)
let my_temp_dir = lazy (CUnix.mktemp_dir "Coq_native" "")

let () = at_exit (fun () ->
    if not !Flags.debug && Lazy.is_val my_temp_dir then
      try
        let d = Lazy.force my_temp_dir in
        Array.iter (fun f -> Sys.remove (Filename.concat d f)) (Sys.readdir d);
        Unix.rmdir d
      with e ->
        Feedback.msg_warning
          Pp.(str "Native compile: failed to cleanup: " ++
              str(Printexc.to_string e) ++ fnl()))

(* We have to delay evaluation of include_dirs because coqlib cannot
   be guessed until flags have been properly initialized. It also lets
   us avoid forcing [my_temp_dir] if we don't need it (eg stdlib file
   without native compute or native conv uses). *)
let include_dirs = ref []
let get_include_dirs () =
  let base = match !include_dirs with
  | [] ->
    [Envars.coqlib () / "kernel"; Envars.coqlib () / "library"]
  | _::_ as l -> l
  in
  if Lazy.is_val my_temp_dir
  then (Lazy.force my_temp_dir) :: base
  else base

(* Pointer to the function linking an ML object into coq's toplevel *)
let load_obj = ref (fun _x -> () : string -> unit)

let rt1 = ref (dummy_value ())
let rt2 = ref (dummy_value ())

let get_ml_filename () =
  let temp_dir = Lazy.force my_temp_dir in
  let filename = Filename.temp_file ~temp_dir "Coq_native" source_ext in
  let prefix = Filename.chop_extension (Filename.basename filename) ^ "." in
  filename, prefix

let write_ml_code fn ?(header=[]) code =
  let header = open_header@header in
  let ch_out = open_out fn in
  let fmt = Format.formatter_of_out_channel ch_out in
  List.iter (pp_global fmt) (header@code);
  close_out ch_out

let error_native_compiler_failed e =
  let msg = match e with
  | Inl (Unix.WEXITED 127) -> Pp.(strbrk "The OCaml compiler was not found. Make sure it is installed, together with findlib.")
  | Inl (Unix.WEXITED n) -> Pp.(strbrk "Native compiler exited with status" ++ str" " ++ int n)
  | Inl (Unix.WSIGNALED n) -> Pp.(strbrk "Native compiler killed by signal" ++ str" " ++ int n)
  | Inl (Unix.WSTOPPED n) -> Pp.(strbrk "Native compiler stopped by signal" ++ str" " ++ int n)
  | Inr e -> Pp.(strbrk "Native compiler failed with error: " ++ strbrk (Unix.error_message e))
  in
  CErrors.user_err msg

let call_compiler ?profile:(profile=false) ml_filename =
  (* The below path is computed from Require statements, by uniquizing
     the paths, see [Library.get_used_load_paths] This is in general
     hacky and we should do a bit better once we move loadpath to its
     own library *)
  let require_load_path = !get_load_paths () in
  (* We assume that installed files always go in .coq-native for now *)
  let install_load_path = List.map (fun dn -> dn / dft_output_dir) require_load_path in
  let include_dirs = List.flatten (List.map (fun x -> ["-I"; x]) (get_include_dirs () @ install_load_path)) in
  let f = Filename.chop_extension ml_filename in
  let link_filename = f ^ ".cmo" in
  let link_filename = Dynlink.adapt_filename link_filename in
  let remove f = if Sys.file_exists f then Sys.remove f in
  remove link_filename;
  remove (f ^ ".cmi");
  let initial_args =
    if Dynlink.is_native then
      ["opt"; "-shared"]
     else
      ["ocamlc"; "-c"]
  in
  let profile_args =
    if profile then
      ["-g"]
    else
      []
  in
  let flambda_args = if Sys.(backend_type = Native) then ["-Oclassic"; "-linscan"] else [] in
  let args =
    initial_args @
      profile_args @
        flambda_args @
      ("-o"::link_filename
       ::"-rectypes"
       ::"-w"::"a"
       ::include_dirs) @
      ["-impl"; ml_filename] in
  if !Flags.debug then Feedback.msg_debug (Pp.str (Envars.ocamlfind () ^ " " ^ (String.concat " " args)));
  try
    let res = CUnix.sys_command (Envars.ocamlfind ()) args in
    match res with
    | Unix.WEXITED 0 -> link_filename
    | Unix.WEXITED _n | Unix.WSIGNALED _n | Unix.WSTOPPED _n ->
      error_native_compiler_failed (Inl res)
  with Unix.Unix_error (e,_,_) ->
    error_native_compiler_failed (Inr e)

let compile fn code ~profile:profile =
  write_ml_code fn code;
  let r = call_compiler ~profile fn in
  if (not !Flags.debug) && Sys.file_exists fn then Sys.remove fn;
  r

type native_library = Nativecode.global list * Nativevalues.symbols

let compile_library (code, symb) fn =
  let header = mk_library_header symb in
  let fn = fn ^ source_ext in
  let basename = Filename.basename fn in
  let dirname = Filename.dirname fn in
  let dirname = dirname / !output_dir in
  let () =
    try Unix.mkdir dirname 0o755
    with Unix.Unix_error (Unix.EEXIST, _, _) -> ()
  in
  let fn = dirname / basename in
  write_ml_code fn ~header code;
  let _ = call_compiler fn in
  if (not !Flags.debug) && Sys.file_exists fn then Sys.remove fn

(* call_linker links dynamically the code for constants in environment or a  *)
(* conversion test. *)
let call_linker ?(fatal=true) ~prefix f upds =
  rt1 := dummy_value ();
  rt2 := dummy_value ();
  if not (Sys.file_exists f) then
    begin
      let msg = "Cannot find native compiler file " ^ f in
      if fatal then CErrors.user_err Pp.(str msg)
      else if !Flags.debug then Feedback.msg_debug (Pp.str msg)
    end
  else
  (try
    if Dynlink.is_native then Dynlink.loadfile f else !load_obj f;
    register_native_file prefix
   with Dynlink.Error _ as exn ->
     let exn = Exninfo.capture exn in
     if fatal then Exninfo.iraise exn
     else if !Flags.debug then Feedback.msg_debug CErrors.(iprint exn));
  match upds with Some upds -> update_locations upds | _ -> ()

let link_library ~prefix ~dirname ~basename =
  (* We try both [output_dir] and [.coq-native], unfortunately from
     [Require] we don't know if we are loading a library in the build
     dir or in the installed layout *)
  let install_location = dirname / dft_output_dir / basename in
  let build_location = dirname / !output_dir / basename in
  let f = if Sys.file_exists build_location then build_location else install_location in
  call_linker ~fatal:false ~prefix f None
