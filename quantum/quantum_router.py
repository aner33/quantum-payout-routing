#!/usr/bin/env python3
"""
Quantum core for smart payout routing.

Picks one provider out of N candidates by solving a one-hot QUBO with QAOA.
Ruby owns all business logic (constraints, weights, cascade, reports); this
script only knows candidates + costs -> ranking.

Protocol
--------
stdin (JSON):
{
  "candidates": [{"provider": "<id>", "cost": <float>}, ...],  # lower cost = better
  "penalty": <float, optional>,   # one-hot constraint strength, auto if omitted
  "p": <int, optional>,           # QAOA depth (reps), default 2
  "shots": <int, optional>,       # sampling shots, default 4096
  "restarts": <int, optional>,    # COBYLA random restarts, default 5
  "seed": <int, optional>,        # default 42, for reproducible runs
  "backend": <"simulator"|"qpu">  # optional, default "simulator"
}

"backend": "qpu" -- COBYLA's ~200 iterations always run on the local
simulator (one hardware job per iteration would be slow/wasteful); only the
final sampling of the optimized circuit goes to a real IBM device. Requires:
    pip install qiskit-ibm-runtime
    python3 -c "from qiskit_ibm_runtime import QiskitRuntimeService; \
        QiskitRuntimeService.save_account(channel='ibm_quantum_platform', token='<YOUR_TOKEN>')"
No package/account/connectivity -> silent fallback to local sampling, noted
in meta.qpu_fallback_reason.

stdout (JSON), success:
{
  "selected": "<provider>",
  "ranking": ["<provider>", ...],            # best -> worst
  "probabilities": {"<provider>": <float>},   # P(measured a valid one-hot state)
  "energies": {"<provider>": <float>},        # exact business cost, for explainability
  "meta": {"n_qubits": .., "p": .., "shots": .., "fallback_classical": bool, ...}
}

stdout (JSON), failure (also exit code 1):
{"error": "<message>", "type": "<ExceptionClassName>"}

No network access, no proprietary solvers: pure Qiskit (Terra) + numpy + scipy.
"""
import sys
import json
import numpy as np
from scipy.optimize import minimize

from qiskit.circuit.library import QAOAAnsatz
from qiskit.quantum_info import SparsePauliOp
from qiskit.primitives import StatevectorEstimator, StatevectorSampler


def sample_on_qpu(bound_circuit, shots, seed):
    """
    Submit ONE job to a real IBM backend for the final sampling step.
    Returns (counts, meta_extra) on success, or (None, meta_extra) if
    hardware isn't reachable -- caller falls back to the local simulator.
    """
    meta_extra = {"requested_backend": "qpu"}
    try:
        from qiskit_ibm_runtime import QiskitRuntimeService, SamplerV2
        from qiskit.transpiler.preset_passmanagers import generate_preset_pass_manager
    except ImportError:
        meta_extra["qpu_fallback_reason"] = "qiskit-ibm-runtime not installed"
        return None, meta_extra

    try:
        service = QiskitRuntimeService()
        backend = service.least_busy(operational=True, simulator=False)
        pm = generate_preset_pass_manager(backend=backend, optimization_level=1)
        isa_circuit = pm.run(bound_circuit)

        sampler = SamplerV2(mode=backend)
        job = sampler.run([isa_circuit], shots=shots)
        result = job.result()[0]
        counts = result.data.meas.get_counts()

        meta_extra["backend_name"] = backend.name
        meta_extra["job_id"] = job.job_id()
        return counts, meta_extra
    except Exception as exc:  # no account, no token, network, queue error, etc.
        meta_extra["qpu_fallback_reason"] = f"{type(exc).__name__}: {exc}"
        return None, meta_extra


def qubo_to_ising(linear, quadratic, n):
    """
    Convert a QUBO  E(x) = sum_i linear[i]*x_i + sum_{i<j} quadratic[i,j]*x_i*x_j
    (x_i in {0,1}) into an Ising Hamiltonian  H = sum h_i Z_i + sum J_ij Z_i Z_j + offset,
    via the standard substitution x_i = (1 - z_i) / 2.
    """
    h = np.zeros(n)
    J = {}
    offset = 0.0

    for i in range(n):
        offset += linear[i] / 2.0
        h[i] += -linear[i] / 2.0

    for (i, j), q in quadratic.items():
        offset += q / 4.0
        h[i] += -q / 4.0
        h[j] += -q / 4.0
        J[(i, j)] = J.get((i, j), 0.0) + q / 4.0

    return h, J, offset


def build_cost_operator(h, J, n):
    """Build the QAOA cost Hamiltonian as a SparsePauliOp over n qubits."""
    terms = []
    for i in range(n):
        if abs(h[i]) < 1e-12:
            continue
        label = ["I"] * n
        label[n - 1 - i] = "Z"  # Qiskit uses little-endian qubit ordering in labels
        terms.append(("".join(label), float(h[i])))
    for (i, j), val in J.items():
        if abs(val) < 1e-12:
            continue
        label = ["I"] * n
        label[n - 1 - i] = "Z"
        label[n - 1 - j] = "Z"
        terms.append(("".join(label), float(val)))
    if not terms:
        terms = [("I" * n, 0.0)]
    return SparsePauliOp.from_list(terms)


def build_qubo(candidates, penalty):
    """One-hot selection QUBO: minimize cost of the chosen candidate,
    subject to exactly one candidate being chosen."""
    n = len(candidates)
    costs = [c["cost"] for c in candidates]
    linear = {i: costs[i] - penalty for i in range(n)}
    quadratic = {(i, j): 2 * penalty for i in range(n) for j in range(i + 1, n)}
    return linear, quadratic, n


def classical_cost(bitstring, costs):
    """Exact business cost of a one-hot bitstring; None if not one-hot."""
    ones = [i for i, b in enumerate(bitstring) if b == "1"]
    if len(ones) != 1:
        return None
    return costs[ones[0]]


def solve(payload):
    candidates = payload["candidates"]
    if not candidates:
        raise ValueError("candidates must be a non-empty list")

    n = len(candidates)
    providers = [c["provider"] for c in candidates]
    costs = [float(c["cost"]) for c in candidates]

    if n == 1:
        return {
            "selected": providers[0],
            "ranking": providers,
            "probabilities": {providers[0]: 1.0},
            "energies": {providers[0]: costs[0]},
            "meta": {"n_qubits": 1, "note": "single candidate, quantum step skipped"},
        }

    # Penalty must dominate the cost spread, or the optimizer may prefer
    # violating the one-hot constraint over picking a slightly worse candidate.
    penalty = float(payload.get("penalty", 2.0 * (max(costs) - min(costs) + 1.0)))
    p = int(payload.get("p", 2))
    shots = int(payload.get("shots", 4096))
    seed = int(payload.get("seed", 42))
    # single COBYLA start can land in a poor local optimum (saw this on
    # op_106 in the case queue); best-of-restarts is the standard fix.
    restarts = int(payload.get("restarts", 5))

    linear, quadratic, _ = build_qubo(candidates, penalty)
    h, J, _offset = qubo_to_ising(linear, quadratic, n)
    cost_op = build_cost_operator(h, J, n)

    ansatz = QAOAAnsatz(cost_operator=cost_op, reps=p)
    estimator = StatevectorEstimator()

    def expectation(params):
        job = estimator.run([(ansatz, cost_op, params)])
        return float(job.result()[0].data.evs)

    rng = np.random.default_rng(seed)
    best_result = None
    for _ in range(max(restarts, 1)):
        x0 = rng.uniform(0, np.pi, size=ansatz.num_parameters)
        candidate_result = minimize(expectation, x0, method="COBYLA", options={"maxiter": 200})
        if best_result is None or candidate_result.fun < best_result.fun:
            best_result = candidate_result
    opt_result = best_result

    bound_circuit = ansatz.assign_parameters(opt_result.x)
    bound_circuit.measure_all()

    backend_choice = payload.get("backend", "simulator")
    qpu_meta = {}
    counts = None

    if backend_choice == "qpu":
        counts, qpu_meta = sample_on_qpu(bound_circuit, shots, seed)

    if counts is None:
        # either "simulator" was requested, or "qpu" was requested but
        # unreachable -- either way, sample locally so we always answer.
        sampler = StatevectorSampler(seed=seed)
        job = sampler.run([bound_circuit], shots=shots)
        counts = job.result()[0].data.meas.get_counts()

    valid = {}
    for bitstring, count in counts.items():
        clean = bitstring.replace(" ", "")
        if classical_cost(clean, costs) is not None:
            valid[clean] = valid.get(clean, 0) + count

    if not valid:
        # Should be rare with a sane penalty; fall back to exact argmin
        # rather than let the router stall on an empty sample.
        ranking_idx = sorted(range(n), key=lambda i: costs[i])
        best = ranking_idx[0]
        return {
            "selected": providers[best],
            "ranking": [providers[i] for i in ranking_idx],
            "probabilities": {providers[best]: 1.0},
            "energies": {providers[i]: costs[i] for i in range(n)},
            "meta": {
                "n_qubits": n, "p": p, "shots": shots, "restarts": restarts,
                "fallback_classical": True,
                "reason": "no valid one-hot bitstring sampled",
            },
        }

    total = sum(valid.values())
    probs_by_bit = {bs: cnt / total for bs, cnt in valid.items()}

    def provider_of(bitstring):
        return providers[bitstring.index("1")]

    probabilities = {}
    for bs, prob in probs_by_bit.items():
        prov = provider_of(bs)
        probabilities[prov] = probabilities.get(prov, 0.0) + prob

    ranking = sorted(probabilities, key=probabilities.get, reverse=True)
    selected = ranking[0]

    return {
        "selected": selected,
        "ranking": ranking,
        "probabilities": probabilities,
        "energies": {providers[i]: costs[i] for i in range(n)},
        "meta": {
            "n_qubits": n, "p": p, "shots": shots, "restarts": restarts,
            "valid_bitstring_prob": sum(valid.values()) / shots,
            "fallback_classical": False,
            "optimizer": "COBYLA",
            "best_expectation": float(opt_result.fun),
            "sampled_on": "qpu" if qpu_meta.get("backend_name") else "simulator",
            **qpu_meta,
        },
    }


def main():
    raw = sys.stdin.read()
    try:
        payload = json.loads(raw)
        output = solve(payload)
    except Exception as exc:  # boundary process: report cleanly, never traceback to stdout
        print(json.dumps({"error": str(exc), "type": type(exc).__name__}))
        sys.exit(1)
    print(json.dumps(output))


if __name__ == "__main__":
    if sys.stdin.isatty():
        # Smoke test without piping anything in: `python3 quantum_router.py`
        demo = {
            "candidates": [
                {"provider": "vipay", "cost": 0.62},
                {"provider": "payflow", "cost": 0.15},
                {"provider": "quickpay", "cost": 0.40},
            ]
        }
        print(json.dumps(solve(demo), indent=2))
    else:
        main()
