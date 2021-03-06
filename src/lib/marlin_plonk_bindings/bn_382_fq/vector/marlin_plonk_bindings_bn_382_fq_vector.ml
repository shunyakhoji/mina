type t

type elt = Marlin_plonk_bindings_bn_382_fq.t

external create : unit -> t = "caml_bn_382_fq_vector_create"

external length : t -> int = "caml_bn_382_fq_vector_length"

external emplace_back : t -> elt -> unit = "caml_bn_382_fq_vector_emplace_back"

external get : t -> int -> elt option = "caml_bn_382_fq_vector_get"
