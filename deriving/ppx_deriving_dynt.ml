open Longident
open Location
open Asttypes
open Parsetree
open Ast_helper
open Ast_convenience

(* Who are we? *)
let deriver = "t"
let me = "[@@deriving t]"

(* How are names derived? We use suffix over prefix *)
let mangle_lid = Ppx_deriving.mangle_lid (`Suffix deriver)
let mangle_type_decl = Ppx_deriving.mangle_type_decl (`Suffix deriver)

(* Name of the stype, used in recursive type definitions*)
let rec_stype_label="__rec_stype"

(* Make accesible the runtime module at runtime *)
let wrap_runtime decls =
  Ppx_deriving.sanitize ~module_:(Lident "Ppx_deriving_dynt_runtime") decls

(* Helpers for error raising *)
let raise_str ?loc ?sub ?if_highlight (s : string) =
  Ppx_deriving.raise_errorf ?sub ?if_highlight ?loc "%s: %s" me s
let sprintf = Format.sprintf

(* More helpers *)
let expand_path = Ppx_deriving.expand_path (* this should mix in library name
                                              at some point *)

(* Combine multiple expressions into a list expression *)
let expr_list ~loc lst =
  Ppx_deriving.fold_exprs (fun acc el ->
      [%expr [%e el] :: [%e acc]]) ([%expr []] :: lst)

(* read options from e.g. [%deriving t { abstract = "Hashtbl.t" }] *)
type options = { abstract : label option ; path : label list }
let parse_options ~path options : options =
  let default = { abstract = None ; path } in
  List.fold_left (fun acc (name, expr) ->
    let loc = expr.pexp_loc in
      match name with
      | "abstract" ->
        let name = match expr.pexp_desc with
          | Pexp_constant (Pconst_string (name, None )) -> name
          | _ -> raise_str ~loc "please provide a string as abstract name"
        in  { acc with abstract = Some name }
      | _ -> raise_str ~loc
               ( sprintf "option %s not supported" name )
    ) default options

let find_index_opt (l : 'a list) (el : 'a) : int option =
  let i = ref 0 in
  let rec f = function
    | [] -> None
    | hd :: _ when hd = el -> Some !i
    | _ :: tl -> incr i ; f tl
  in f l

(* Construct ttype generator from core type *)
let rec str_of_core_type ~opt ~recurse ~free ({ ptyp_loc = loc ; _ } as ct) =
  let fail () = raise_str ~loc "type not yet supported" in
  let rc = str_of_core_type ~opt ~recurse ~free in
  let t = match ct.ptyp_desc with
    | Ptyp_tuple l ->
      let args = List.rev_map rc l |> List.fold_left (fun acc e ->
          [%expr stype_of_ttype [%e e] :: [%e acc]]) [%expr []]
      in
      [%expr ttype_of_stype (DT_tuple [%e args])]
    | Ptyp_constr (id, args) ->
      if id.txt = Lident recurse then
        [%expr ttype_of_stype [%e evar rec_stype_label]]
      else
        let id' = { id with txt = mangle_lid id.txt} in
        List.fold_left
          (fun acc e -> [%expr [%e acc] [%e rc e]])
          [%expr [%e Exp.ident id']] args
    | Ptyp_var vname -> begin
        match find_index_opt free vname with
        | None -> assert false
        | Some i -> [%expr ttype_of_stype (DT_var [%e int i])]
      end
    | _ -> fail ()
  in
  match opt.abstract with
  | Some name ->
    [%expr ttype_of_stype( DT_abstract ([%e str name],[]))]
  | None -> t

let stypes_of_free ~loc free =
  List.mapi (fun i _v -> [%expr DT_var [%e int i]]) free |> list

(* Construct record ttypes *)
let str_of_record_labels ?inline ~loc ~opt ~name ~free ~recurse l =
  let ll = List.rev_map (fun {pld_loc = loc; pld_name; pld_type; _ } ->
      let t = str_of_core_type ~opt ~recurse ~free pld_type in
      [%expr
        ([%e str pld_name.txt], [], stype_of_ttype [%e t])]
    ) l |> expr_list ~loc
  in
  match inline with
  | None ->
    [%expr Internal.create_record_type [%e str name]
        [%e stypes_of_free ~loc free]
        (fun [%p pvar rec_stype_label] -> [%e ll], Record_regular)
           |> ttype_of_stype ]
  | Some i ->
    [%expr Internal.create_record_type [%e str name]
        [%e stypes_of_free ~loc free]
        (fun _ -> [%e ll], Record_inline [%e int i])
           |> ttype_of_stype ]

(* Construct variant ttypes *)
let str_of_variant_constructors ~loc ~opt ~name ~free ~recurse l =
  let nconst_tag = ref 0 in
  let ll = List.rev_map (fun {pcd_loc = loc; pcd_name; pcd_args; _ } ->
      match pcd_args with
      | Pcstr_tuple ctl ->
        if ctl <> [] then incr nconst_tag;
        let l = List.rev_map (fun ct ->
            str_of_core_type ~opt ~recurse ~free ct
            |> fun e -> [%expr stype_of_ttype [%e e]]
          ) ctl in
        [%expr ([%e str pcd_name.txt], [],
                C_tuple [%e expr_list ~loc l])]
      | Pcstr_record lbl ->
        let r =
          str_of_record_labels ~inline:!nconst_tag ~recurse ~free
            ~opt ~loc ~name:(sprintf "%s.%s" name pcd_name.txt) lbl
        in
        incr nconst_tag;
        [%expr ([%e str pcd_name.txt], [], C_inline [%e r])]
    ) l |> expr_list ~loc
  in
  [%expr Internal.create_variant_type [%e str name]
      [%e stypes_of_free ~loc free]
      (fun [%p pvar rec_stype_label] -> [%e ll]) |> ttype_of_stype ]

let free_vars_of_type_decl td =
  List.rev_map (fun (ct, _variance) ->
      match ct.ptyp_desc with
      | Ptyp_var name -> name
      | _ -> raise_str "type parameter not yet supported"
    ) td.ptype_params

(* generate type expressions of the form 'a list ttype *)
let basetyp_of_type_decl ~loc td =
  let ct  = Ppx_deriving.core_type_of_type_decl td in
  [%type: [%t ct] Dynt.Types.ttype]

(* generate type expresseion of the form 'a ttype -> 'a list ttype *)
let typ_of_free_vars ~loc ~basetyp free =
  List.fold_left (fun acc name ->
      [%type: [%t Typ.var name] Dynt.Types.ttype -> [%t acc]])
    basetyp free

(* Type declarations in structure.  Builds e.g.
 * let <type>_t : (<a> * <b>) ttype = pair <b>_t <a>_t
 *)
let str_of_type_decl ~options ~path ({ ptype_loc = loc ; _} as td) =
  let opt = parse_options ~path options in
  let name = td.ptype_name.txt in
  let recurse = name in
  let free = free_vars_of_type_decl td in
  let unclosed = match td.ptype_kind with
    | Ptype_abstract -> begin match td.ptype_manifest with
        | None -> raise_errorf ~loc "no manifest found"
        | Some ct -> str_of_core_type ~opt ~recurse ~free ct
      end
    | Ptype_variant l ->
      str_of_variant_constructors ~loc ~opt ~name ~recurse ~free l
    | Ptype_record l -> str_of_record_labels ~loc ~opt ~name ~recurse ~free l
    | Ptype_open ->
      raise_str ~loc "type kind not yet supported"
  in
  let id = mangle_type_decl td in
  let basetyp = basetyp_of_type_decl ~loc td in
  if free = [] then
    [Vb.mk (Pat.constraint_ (pvar id) basetyp) (wrap_runtime unclosed)]
  else begin
    let typ = typ_of_free_vars ~loc ~basetyp free in
    let subst =
      let arr = List.map (fun v ->
          [%expr stype_of_ttype [%e evar v]]) free
      in
      List.fold_left (fun acc v -> lam (pvar v) acc)
        [%expr ttype_of_stype (
            substitute [%e Exp.array arr] (stype_of_ttype [%e evar id]))]
        free
    in
    [Vb.mk (pvar id) (wrap_runtime unclosed);
     Vb.mk (Pat.constraint_ (pvar id) typ) (wrap_runtime subst)]
  end

(* Type declarations in signature. Generates
 * val <type>_t : <type> ttype
 *)
let sig_of_type_decl ~options ~path ({ ptype_loc = loc ; _} as td) =
  let _opt = parse_options ~path options in
  let basetyp =
    match td.ptype_kind with
    | Ptype_abstract
    | Ptype_record _
    | Ptype_variant _ -> basetyp_of_type_decl ~loc td
    | _ -> raise_str ~loc "cannot handle this type in signatures yet"
  in
  let typ = typ_of_free_vars ~loc ~basetyp (free_vars_of_type_decl td) in
  [Val.mk {txt=(mangle_type_decl td); loc} typ]

(* Register the handler for type declarations in signatures and structures *)
let () =
  let type_decl_str ~options ~path type_decls =
    List.map (str_of_type_decl ~options ~path) type_decls
    |> List.concat
    |> List.map (fun x -> Str.value Nonrecursive [x])
  and type_decl_sig ~options ~path type_decls =
    List.map (sig_of_type_decl ~options ~path) type_decls
    |> List.concat
    |> List.map Sig.value
  in
  Ppx_deriving.(register (create deriver ~type_decl_str ~type_decl_sig ()))
