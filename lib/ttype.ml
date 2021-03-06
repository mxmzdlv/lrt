(******************************************************************************)
(*  Copyright (C) 2020 by LexiFi.                                             *)
(*                                                                            *)
(*  This source file is released under the terms of the MIT license as part   *)
(*  of the lrt package. Details can be found in the attached LICENSE file.    *)
(******************************************************************************)

type 'a t = Stype.t

type dynamic = Dyn : 'a t * 'a -> dynamic

let to_stype : _ t -> Stype.t = fun a -> a

let print fmt t = Format.fprintf fmt "%a" Stype.print (to_stype t)

let remove_outer_props = Stype.remove_outer_props

let consume_outer_props = Stype.consume_outer_props

let add_props props t = Stype.DT_prop (props, t)

let split_arrow t =
  match remove_outer_props t with
  | DT_arrow (_, t1, t2) -> (t1, t2)
  | _ -> assert false

let build_arrow t1 t2 = Stype.DT_arrow ("", t1, t2)

let fst = function Stype.DT_tuple [ t; _ ] -> t | _ -> assert false

let snd = function Stype.DT_tuple [ _; t ] -> t | _ -> assert false

let abstract_name t =
  match Stype.remove_outer_props t with
  | DT_abstract (name, _) -> Some name
  | _ -> None

let equality t1 t2 =
  if Stype.equality t1 t2 then Some (Obj.magic TypEq.refl) else None

let equality_modulo_props t1 t2 =
  if Stype.equality_modulo_props t1 t2 then Some (Obj.magic TypEq.refl)
  else None

type is_t = Ttype : 'a t -> is_t

let of_stype s = Ttype (Obj.magic s)

let t a =
  let t = to_stype a in
  Stype.DT_abstract ("Lrt.Ttype.t", [ t ]) |> Obj.magic
