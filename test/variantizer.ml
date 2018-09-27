open Dynt
open Variant

let variant_round t value =
  to_variant ~t value |> of_variant ~t

let string_round t value =
  to_variant ~t value
  |> Format.asprintf "%a" Variant.print_variant
  |> Variant_lexer.variant_of_string
  |> of_variant ~t

let round cmp t v =
  cmp v (variant_round t v) = 0 &&
  cmp v (string_round t v) = 0

let lazy_compare a b = compare (Lazy.force a) (Lazy.force b)
let lazy_round t v = round lazy_compare t v
let round t v = round compare t v

let shows t v =
  Format.printf "%a\n%!" print_variant (to_variant ~t v)

let showv t v =
  Format.printf "%a\n%!" (Print.print ~t:Variant.t) (to_variant ~t v)

type a = (int * int) [@@deriving t]

let%test _ = round a_t (-1, 3)
let%test _ = round a_t (max_int, min_int)

type b = float list [@@deriving t]

let%test _ = round b_t [0.; neg_infinity; infinity; max_float; min_float;
                        1.17e99; 1.17e-99; nan]

let%test _ = round unit_t ()

type c = bool Lazy.t [@patch lazy_t] [@@deriving t]

let%test _ =
  lazy_round c_t (lazy (Random.self_init (); Random.bool ()))

type d = { d1 : int; d2 : float} [@@deriving t]

let ht = Hashtbl.create 3
let () = Hashtbl.add ht "a" (Some {d1=1;d2=nan});
  Hashtbl.add ht "b" (Some {d1=max_int;d2=1e42});
  Hashtbl.add ht "c" None

let ht_t = hashtbl_t string_t (option_t d_t)

let%test _ = round ht_t ht

let%expect_test _ = shows ht_t ht;
  [%expect {|
    [("c", None); ("b", Some{d1 = 4611686018427387903; d2 = 1e+42});
     ("a", Some{d1 = 1; d2 = nan})] |}]