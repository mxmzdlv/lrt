module Step : sig
  type t
  val compare : t -> t -> int

  type maybe_free =
    | Step of t * Stype.t list
    | Var of int (* DT_var *)

  val of_stype : modulo_props: bool -> Stype.t -> maybe_free
end = struct
  type base = | Int | Float | String | Array | List | Option | Arrow
  type t =
    | Base of base
    | Tuple of int
    | Props of Stype.properties
    | Abstract of int * string (* arity, name *)
    | Record of string * Stype.record_repr * ( string * Stype.properties) list

  let map_record name flds repr =
    let flds, stypes = List.fold_left (fun (flds, stypes) (name, prop, s) ->
        ((name, prop) :: flds, s :: stypes)) ([], []) flds
    in (name, repr, flds), stypes

  type maybe_free =
    | Step of t * Stype.t list
    | Var of int (* DT_var *)

  let rec of_stype: modulo_props: bool -> Stype.t -> maybe_free =
    fun ~modulo_props -> function
      | DT_int -> Step (Base Int, [])
      | DT_float -> Step (Base Float, [])
      | DT_string -> Step (Base String, [])
      | DT_list a -> Step (Base List, [a])
      | DT_array a -> Step (Base Array, [a])
      | DT_option a -> Step (Base Option, [a])
      | DT_arrow (_, a, b) -> Step (Base Arrow, [a; b])
      | DT_prop (_, s) when modulo_props -> of_stype ~modulo_props s
      | DT_prop (p, s) -> Step (Props p, [s])
      | DT_tuple l -> Step (Tuple (List.length l), l)
      | DT_abstract (name, args) ->
        Step (Abstract (List.length args, name), args)
      | DT_node { rec_descr = DT_record {record_fields; record_repr}
                ; rec_name; _ } ->
        let (name, repr, flds), types =
          map_record rec_name record_fields record_repr
        in
        (* TODO: verify, that rec_args are indeed irrelevant *)
        (* TODO: The same record can be defined twice in different modules
           and pass this comparison. Solution: insert unique ids on
           [@@deriving t]. Or check what the existing rec_uid is doing.
           This would speed up comparison quite a bit, ie. only args need
           to be compared *)
        Step (Record (name, repr, flds), types)
      | DT_node _ -> failwith "TODO: handle variants"
      | DT_object _ -> failwith "TODO: handle objects"
      | DT_var i -> Var i

  let compare = compare
  (* TODO: A less naive compare may speed up things significantly. *)

end

module DicriminationTree : sig
  type 'a t
  type key = Stype.t
  val empty : modulo_props: bool -> 'a t
  val add : key -> 'a -> 'a t -> 'a t
  val get : key -> 'a t -> 'a option
end = struct
  (* On each level of the discrimination tree, we discriminate on the
     outermost structure of the stype using [Step.of_stype]. When stype children
     are present, they are used depth-first to further discriminate. *)

  type key = Stype.t
  module Map = Map.Make(Step)

  type 'a tree =
    | Leave of { value: 'a; n_free: int}
    | Inner of { map: 'a tree Map.t; free: (int * 'a tree) option }

  type 'a t = { modulo_props: bool
              ; tree: 'a tree
              ; mutable last_free: int }

  let empty ~modulo_props = { modulo_props
                            ; tree = Inner { map = Map.empty
                                           ; free = None }
                            ; last_free = -1
                            }

  let get stype t =
    let get_step s =
      let modulo_props = t.modulo_props in
      match Step.of_stype ~modulo_props s with
      | Step.Step (s, l) -> (s, l)
      | _ -> failwith "TODO: allow free variable in query"
    in
    let rec traverse stack subst tree =
      match stack, tree with
      | [], Leave {value; _} -> Some value (* TODO: return substitution *)
      | hd :: tl, Inner node -> begin
          let step, children = get_step hd in
          match Map.find_opt step node.map with
          | Some tree -> traverse (children @ tl) subst tree
          | None -> match node.free with
            | None -> None
            | Some (id, tree) -> traverse tl ((id, hd) :: subst) tree
        end
      | [], _
      | _ :: _, Leave _ ->
        assert false (* This should be impossible. [Step.of_stype] should
                        uniquely identify the number of children. *)
    in traverse [stype] [] t.tree

  let add stype value t =
    let get_step =
      let modulo_props = t.modulo_props in
      Step.of_stype ~modulo_props
    in
    let rec traverse stack free_vars tree =
      match stack, tree with
      | [], Leave _ -> raise (Invalid_argument "type already registered")
      | [], Inner {map; free = _} ->
        assert (Map.is_empty map);
        (* TODO: store mapping between DT_var i and Free i' in Leave *)
        Leave {value; n_free = List.length free_vars}
      | hd :: tl, Inner node -> begin
          match get_step hd with
          | Var i ->
            let free = match node.free with
              | Some (id, tree) ->
                let tree = traverse tl ((id ,i) :: free_vars) tree in
                Some (id, tree)
              | None ->
                let id = succ t.last_free in
                t.last_free <- id;
                let tree = Inner {map = Map.empty; free = None} in
                let tree = traverse tl ((id ,i) :: free_vars) tree in
                Some (id, tree)
            in Inner {node with free}
          | Step (step, children) ->
            let tree =
              match Map.find_opt step node.map with
              | None -> Inner {map = Map.empty; free = None}
              | Some tree -> tree
            in
            let map =
              Map.add step (traverse (children @ tl) free_vars tree) node.map
            in Inner { node with map }
        end
      | _ :: _ , Leave _ -> assert false
    in {t with tree = traverse [stype] [] t.tree}
end

let%test _ =
  let add typ = DicriminationTree.add (Ttype.to_stype typ) in
  let get typ = DicriminationTree.get (Ttype.to_stype typ) in
  let open Std in
  let t = DicriminationTree.empty ~modulo_props:true
          |> add (list_t int_t) 1
          |> add (option_t string_t) 2
          |> add int_t 3
          |> DicriminationTree.add (DT_list (DT_var 0)) 4
          |> DicriminationTree.add (DT_var 0) 42
  in
  List.for_all (fun x -> x)
    [ get int_t t = Some 3
    ; get (list_t string_t) t = Some 4
    ; get (list_t int_t) t = Some 1
    ; get (option_t string_t) t = Some 2
    ; get (option_t int_t) t = None (* TODO: Why is this not Some 42 *)
    ]

module type C0 = sig
  include Unify.T0
  type res
  val f: t -> res
end

module type C1 = sig
  include Unify.T1
  type res
  val f: 'a Ttype.t -> 'a t -> res
end

module type C2 = sig
  include Unify.T2
  type res
  val f: 'a Ttype.t -> 'b Ttype.t -> ('a, 'b) t -> res
end

type 'a candidate =
  | T0 of (module C0 with type res = 'a)
  | T1 of (module C1 with type res = 'a)
  | T2 of (module C2 with type res = 'a)

type 'a compiled = 'a candidate list

type 'a t = 'a candidate list * ('a compiled Lazy.t)

let compile : type res. res candidate list -> res t =
  fun candidates -> (candidates, lazy (List.rev candidates))
(* This implies oldest added is tried first. What do we want? *)
(* TODO: Build some efficient data structure. *)

let empty : 'a t = [], lazy []

let add (type t res) ~(t: t Ttype.t) ~(f: t -> res) (lst, _) =
  T0 (module struct
    type nonrec t = t [@@deriving t]
    type nonrec res = res
    let f = f end) :: lst
  |> compile

let add0 (type a) (module C : C0 with type res = a) (lst, _) =
  T0 (module C : C0 with type res = a) :: lst
  |> compile

let add1 (type a) (module C : C1 with type res = a) (lst, _) =
  T1 (module C : C1 with type res = a) :: lst
  |> compile

let add2 (type a) (module C : C2 with type res = a) (lst, _) =
  T2 (module C : C2 with type res = a) :: lst
  |> compile

let apply' : type res. res t -> Ttype.dynamic -> res =
  fun (_, lazy matcher) (Ttype.Dyn (t,x)) ->
    let (module B) = Unify.t0 t
    and (module P) = Unify.init ~modulo_props:false in
    let rec loop = function
      | [] -> raise Not_found
      | T0 (module A : C0 with type res = res) :: tl ->
        begin try
            let module U = Unify.U0 (P) (A) (B) in
            let TypEq.Eq = U.eq in A.f x
          with Unify.Not_unifiable -> loop tl end
      | T1 (module A : C1 with type res = res) :: tl ->
        begin try
            let module U = Unify.U1 (P) (A) (B) in
            let TypEq.Eq = U.eq in A.f U.a_t x
          with Unify.Not_unifiable -> loop tl end
      | T2 (module A : C2 with type res = res) :: tl ->
        begin try
            let module U = Unify.U2 (P) (A) (B) in
            let TypEq.Eq = U.eq in A.f U.a_t U.b_t x
          with Unify.Not_unifiable -> loop tl end
    in loop matcher

let apply matcher ~t x = apply' matcher (Ttype.Dyn (t, x))
