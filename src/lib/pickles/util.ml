open Core_kernel
open Import
open Pickles_types

type m = Abc.Label.t = A | B | C

let rec absorb : type a g1 f scalar.
       absorb_field:(f -> unit)
    -> absorb_scalar:(scalar -> unit)
    -> g1_to_field_elements:(g1 -> f list)
    -> (a, < scalar: scalar ; g1: g1 ; g1_opt: g1 >) Type.t
    -> a
    -> unit =
 fun ~absorb_field ~absorb_scalar ~g1_to_field_elements ty t ->
  match ty with
  | PC ->
      List.iter ~f:absorb_field (g1_to_field_elements t)
  | Scalar ->
      absorb_scalar t
  | Without_degree_bound ->
      Array.iter
        ~f:(Fn.compose (List.iter ~f:absorb_field) g1_to_field_elements)
        t
  | With_degree_bound ->
      Array.iter t.unshifted ~f:(fun t ->
          absorb ~absorb_field ~absorb_scalar ~g1_to_field_elements PC t ) ;
      absorb ~absorb_field ~absorb_scalar ~g1_to_field_elements PC t.shifted
  | ty1 :: ty2 ->
      let absorb t =
        absorb t ~absorb_field ~absorb_scalar ~g1_to_field_elements
      in
      let t1, t2 = t in
      absorb ty1 t1 ; absorb ty2 t2

let ones_vector : type f n.
       first_zero:f Snarky_backendless.Cvar.t
    -> (module Snarky_backendless.Snark_intf.Run with type field = f)
    -> n Nat.t
    -> (f Snarky_backendless.Cvar.t Snarky_backendless.Boolean.t, n) Vector.t =
 fun ~first_zero (module Impl) n ->
  let open Impl in
  let rec go : type m.
      Boolean.var -> int -> m Nat.t -> (Boolean.var, m) Vector.t =
   fun value i m ->
    match m with
    | Z ->
        []
    | S m ->
        let value =
          Boolean.(value && not (Field.equal first_zero (Field.of_int i)))
        in
        value :: go value (i + 1) m
  in
  go Boolean.true_ 0 n

let split_last xs =
  let rec go acc = function
    | [x] ->
        (List.rev acc, x)
    | x :: xs ->
        go (x :: acc) xs
    | [] ->
        failwith "Empty list"
  in
  go [] xs

let boolean_constrain (type f)
    (module Impl : Snarky_backendless.Snark_intf.Run with type field = f)
    (xs : Impl.Boolean.var list) : unit =
  let open Impl in
  assert_all (List.map xs ~f:(fun x -> Constraint.boolean (x :> Field.t)))

(* Should seal constants too *)
let seal (type f)
    (module Impl : Snarky_backendless.Snark_intf.Run with type field = f)
    (x : Impl.Field.t) : Impl.Field.t =
  let open Impl in
  match Field.to_constant_and_terms x with
  | None, [] ->
      Field.zero
  | Some c, [] ->
      Field.constant c
  | None, [(x, i)] ->
      let v = Snarky_backendless.Cvar.Var (Impl.Var.index i) in
      if Field.Constant.(equal x one) then v else Field.scale v x
  | _ ->
      let y = exists Field.typ ~compute:As_prover.(fun () -> read_var x) in
      Field.Assert.equal x y ; y
