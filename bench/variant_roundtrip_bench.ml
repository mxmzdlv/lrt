open Dynt

type t = Variant_roundtrip_type.t list
[@@deriving t]

let filename =
  if Array.length Sys.argv > 1 then
    Sys.argv.(1)
  else begin
    Printf.eprintf "Please provide filename of data as first argument";
    exit 1
  end

let x = Variant.value_of_variant_in_file ~t filename

let[@landmark "test"] run () =
  let[@landmark "to_variant"] v = Variant.to_variant ~t x in
  let[@landmark "of_variant"] x' = Variant.of_variant ~t v in
  ignore(x')

let _ = List.init 10 (fun _ -> run ())