#[allow(unused_imports)]
use algebra::pasta::{
    fp::Fp,
    pallas::Affine as GAffineOther,
    vesta::{Affine as GAffine, VestaParameters},
};

use plonk_5_wires_circuits::constraints::ConstraintSystem;
use plonk_5_wires_circuits::gate::CircuitGate;
use plonk_5_wires_circuits::wires::Wire;

use ff_fft::EvaluationDomain;

use commitment_dlog::srs::SRS;
use plonk_5_wires_protocol_dlog::index::{Index as DlogIndex, SRSSpec};

use std::{
    fs::{File, OpenOptions},
    io::{BufReader, BufWriter, Seek, SeekFrom::Start},
    rc::Rc,
};

use crate::index_serialization_5_wires;
use crate::pasta_fp_urs::CamlPastaFpUrs;
use crate::plonk_5_wires_gate::{CamlPlonkGate, CamlPlonkWire, CamlPlonkWires};

pub struct CamlPastaFpPlonkGateVector(Vec<CircuitGate<Fp>>);
pub type CamlPastaFpPlonkGateVectorPtr = ocaml::Pointer<CamlPastaFpPlonkGateVector>;

extern "C" fn caml_pasta_fp_plonk_5_wires_gate_vector_finalize(v: ocaml::Value) {
    let v: CamlPastaFpPlonkGateVectorPtr = ocaml::FromValue::from_value(v);
    unsafe { v.drop_in_place() };
}

ocaml::custom!(CamlPastaFpPlonkGateVector {
    finalize: caml_pasta_fp_plonk_5_wires_gate_vector_finalize,
});

#[ocaml::func]
pub fn caml_pasta_fp_plonk_5_wires_gate_vector_create() -> CamlPastaFpPlonkGateVector {
    CamlPastaFpPlonkGateVector(Vec::new())
}

#[ocaml::func]
pub fn caml_pasta_fp_plonk_5_wires_gate_vector_add(
    mut v: CamlPastaFpPlonkGateVectorPtr,
    gate: CamlPlonkGate<Vec<Fp>>,
) {
    v.as_mut().0.push(CircuitGate {
        typ: gate.typ.into(),
        row: gate.row as usize,
        wires: [
            gate.wires.l.into(),
            gate.wires.r.into(),
            gate.wires.o.into(),
            gate.wires.q.into(),
            gate.wires.p.into()
        ],
        c: gate.c,
    });
}

#[ocaml::func]
pub fn caml_pasta_fp_plonk_5_wires_gate_vector_get(
    v: CamlPastaFpPlonkGateVectorPtr,
    i: ocaml::Int,
) -> CamlPlonkGate<Vec<Fp>> {
    let gate = &(v.as_ref().0)[i as usize];
    let c = gate.c.iter().map(|x| *x).collect();
    CamlPlonkGate {
        typ: (&gate.typ).into(),
        row: gate.row as isize,
        wires: CamlPlonkWires
        {
            l: (&gate.wires[0]).into(),
            r: (&gate.wires[1]).into(),
            o: (&gate.wires[2]).into(),
            q: (&gate.wires[3]).into(),
            p: (&gate.wires[4]).into(),
        },
        c,
    }
}

#[ocaml::func]
pub fn caml_pasta_fp_plonk_5_wires_gate_vector_wrap
(
    mut v: CamlPastaFpPlonkGateVectorPtr,
    t: CamlPlonkWire,
    h: CamlPlonkWire,
)
{
    (v.as_mut().0)[t.row as usize].wires[t.col as usize] =
        Wire
        {
            row: h.row as usize,
            col: h.col as usize,
        };
}

/* Boxed so that we don't store large proving indexes in the OCaml heap. */

pub struct CamlPastaFpPlonkIndex<'a>(pub Box<DlogIndex<'a, GAffine>>, pub Rc<SRS<GAffine>>);
pub type CamlPastaFpPlonkIndexPtr<'a> = ocaml::Pointer<CamlPastaFpPlonkIndex<'a>>;

extern "C" fn caml_pasta_fp_plonk_5_wires_index_finalize(v: ocaml::Value) {
    let mut v: CamlPastaFpPlonkIndexPtr = ocaml::FromValue::from_value(v);
    unsafe {
        v.as_mut_ptr().drop_in_place();
    }
}

ocaml::custom!(CamlPastaFpPlonkIndex<'a> {
    finalize: caml_pasta_fp_plonk_5_wires_index_finalize,
});

#[ocaml::func]
pub fn caml_pasta_fp_plonk_5_wires_index_create(
    gates: CamlPastaFpPlonkGateVectorPtr,
    public: ocaml::Int,
    urs: CamlPastaFpUrs,
) -> Result<CamlPastaFpPlonkIndex<'static>, ocaml::Error> {
    let gates: Vec<_> = gates.as_ref().0.clone();
    let (endo_q, _endo_r) = commitment_dlog::srs::endos::<GAffineOther>();
    let cs =
        match ConstraintSystem::<Fp>::create(gates, oracle::pasta::fp5::params(), public as usize)
        {
            None => Err(ocaml::Error::failwith(
                "caml_pasta_fp_plonk_5_wires_index_create: could not create constraint system",
            )
            .err()
            .unwrap())?,
            Some(cs) => cs,
        };
    let urs_copy = Rc::clone(&*urs);
    let urs_copy_outer = Rc::clone(&*urs);
    let srs = {
        // We know that the underlying value is still alive, because we never convert any of our
        // Rc<_>s into weak pointers.
        SRSSpec::Use(unsafe { &*Rc::into_raw(urs_copy) })
    };
    Ok(CamlPastaFpPlonkIndex(
        Box::new(DlogIndex::<GAffine>::create(
            cs,
            oracle::pasta::fq5::params(),
            endo_q,
            srs,
        )),
        urs_copy_outer,
    ))
}

#[ocaml::func]
pub fn caml_pasta_fp_plonk_5_wires_index_max_degree(index: CamlPastaFpPlonkIndexPtr) -> ocaml::Int {
    index.as_ref().0.srs.get_ref().max_degree() as isize
}

#[ocaml::func]
pub fn caml_pasta_fp_plonk_5_wires_index_public_inputs(index: CamlPastaFpPlonkIndexPtr) -> ocaml::Int {
    index.as_ref().0.cs.public as isize
}

#[ocaml::func]
pub fn caml_pasta_fp_plonk_5_wires_index_domain_d1_size(index: CamlPastaFpPlonkIndexPtr) -> ocaml::Int {
    index.as_ref().0.cs.domain.d1.size() as isize
}

#[ocaml::func]
pub fn caml_pasta_fp_plonk_5_wires_index_domain_d4_size(index: CamlPastaFpPlonkIndexPtr) -> ocaml::Int {
    index.as_ref().0.cs.domain.d4.size() as isize
}

#[ocaml::func]
pub fn caml_pasta_fp_plonk_5_wires_index_domain_d8_size(index: CamlPastaFpPlonkIndexPtr) -> ocaml::Int {
    index.as_ref().0.cs.domain.d8.size() as isize
}

#[ocaml::func]
pub fn caml_pasta_fp_plonk_5_wires_index_read(
    offset: Option<ocaml::Int>,
    urs: CamlPastaFpUrs,
    path: String,
) -> Result<CamlPastaFpPlonkIndex<'static>, ocaml::Error> {
    let file = match File::open(path) {
        Err(_) => Err(
            ocaml::Error::invalid_argument("caml_pasta_fp_plonk_5_wires_index_read")
                .err()
                .unwrap(),
        )?,
        Ok(file) => file,
    };
    let mut r = BufReader::new(file);
    match offset {
        Some(offset) => {
            r.seek(Start(offset as u64))?;
        }
        None => (),
    };
    let urs_copy = Rc::clone(&*urs);
    let urs_copy_outer = Rc::clone(&*urs);
    let srs = {
        // We know that the underlying value is still alive, because we never convert any of our
        // Rc<_>s into weak pointers.
        unsafe { &*Rc::into_raw(urs_copy) }
    };
    let t = index_serialization_5_wires::read_plonk_index(
        oracle::pasta::fp5::params(),
        oracle::pasta::fq5::params(),
        srs,
        &mut r,
    )?;
    Ok(CamlPastaFpPlonkIndex(Box::new(t), urs_copy_outer))
}

#[ocaml::func]
pub fn caml_pasta_fp_plonk_5_wires_index_write(
    append: Option<bool>,
    index: CamlPastaFpPlonkIndexPtr<'static>,
    path: String,
) -> Result<(), ocaml::Error> {
    let file = match OpenOptions::new().append(append.unwrap_or(true)).open(path) {
        Err(_) => Err(
            ocaml::Error::invalid_argument("caml_pasta_fp_plonk_5_wires_index_write")
                .err()
                .unwrap(),
        )?,
        Ok(file) => file,
    };
    let mut w = BufWriter::new(file);
    index_serialization_5_wires::write_plonk_index(&index.as_ref().0, &mut w)?;
    Ok(())
}
