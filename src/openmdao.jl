import Base.convert
using PyCall
using OpenMDAO
using LinearAlgebra: norm

struct CCBladeResidualComp
    num_nodes
    num_radial
    af
    B
    turbine
    debug_print
    inputs
    outputs
    partials
end

convert(::Type{CCBladeResidualComp}, po::PyObject) = CCBladeResidualComp(
    po.num_nodes, po.num_radial, po.af, po.B, po.turbine, po.debug_print,
    po.inputs, po.outputs, po.partials)

function CCBladeResidualComp(; num_nodes, num_radial, af, B, turbine, debug_print)

    # Putting these two lines at the top level of this file doesn't work:
    # get_rows_cols will be a "Null" PyObject, and then the first call to
    # get_rows_cols will give a nasty segfault.
    pyccblade = pyimport("ccblade.ccblade_jl")
    get_rows_cols = pyccblade.get_rows_cols

    input_data = [
        VarData("r", [1, num_radial], 1., "m")
        VarData("chord", [1, num_radial], 1., "m")
        VarData("theta", [1, num_radial], 1., "rad")
        VarData("Vx", [num_nodes, num_radial], 1., "m/s")
        VarData("Vy", [num_nodes, num_radial], 1., "m/s")
        VarData("rho", [num_nodes, 1], 1., "kg/m**3")
        VarData("mu", [num_nodes, 1], 1., "N/m**2*s")
        VarData("asound", [num_nodes, 1], 1., "m/s")
        VarData("Rhub", [1, 1], 1., "m")
        VarData("Rtip", [1, 1], 1., "m")
        VarData("precone", [1, 1], 1., "rad")]

    output_data = [
        VarData("phi", [num_nodes, num_radial], 1., "rad"),
        VarData("Np", [num_nodes, num_radial], 1., "N/m"),
        VarData("Tp", [num_nodes, num_radial], 1., "N/m"),
        VarData("a", [num_nodes, num_radial], 1.),
        VarData("ap", [num_nodes, num_radial], 1.),
        VarData("u", [num_nodes, num_radial], 1., "m/s"),
        VarData("v", [num_nodes, num_radial], 1., "m/s"),
        VarData("W", [num_nodes, num_radial], 1., "m/s"),
        VarData("cl", [num_nodes, num_radial], 1.),
        VarData("cd", [num_nodes, num_radial], 1.),
        VarData("F", [num_nodes, num_radial], 1.)]

    partials_data = Array{PartialsData, 1}()

    rows, cols = get_rows_cols(
        of_shape=(num_nodes, num_radial), of_ss="ij",
        wrt_shape=(1,), wrt_ss="k")
    of_names = ["phi", "Np", "Tp", "a", "ap", "u", "v", "W", "cl", "cd", "F"]
    for name in of_names
        push!(partials_data, PartialsData(name, "Rhub", rows=rows, cols=cols))
        push!(partials_data, PartialsData(name, "Rtip", rows=rows, cols=cols))
        push!(partials_data, PartialsData(name, "precone", rows=rows, cols=cols))
    end

    rows, cols = get_rows_cols(
        of_shape=(num_nodes, num_radial), of_ss="ij",
        wrt_shape=(num_radial,), wrt_ss="j")
    for name in of_names
        push!(partials_data, PartialsData(name, "r", rows=rows, cols=cols))
        push!(partials_data, PartialsData(name, "chord", rows=rows, cols=cols))
        push!(partials_data, PartialsData(name, "theta", rows=rows, cols=cols))
    end

    rows, cols = get_rows_cols(
        of_shape=(num_nodes, num_radial), of_ss="ij",
        wrt_shape=(num_nodes,), wrt_ss="i")
    for name in of_names
        push!(partials_data, PartialsData(name, "rho", rows=rows, cols=cols))
        push!(partials_data, PartialsData(name, "mu", rows=rows, cols=cols))
        push!(partials_data, PartialsData(name, "asound", rows=rows, cols=cols))
    end

    rows, cols = get_rows_cols(
        of_shape=(num_nodes, num_radial), of_ss="ij",
        wrt_shape=(num_nodes, num_radial), wrt_ss="ij")
    for name in of_names
        push!(partials_data, PartialsData(name, "Vx", rows=rows, cols=cols))
        push!(partials_data, PartialsData(name, "Vy", rows=rows, cols=cols))
        push!(partials_data, PartialsData(name, "phi", rows=rows, cols=cols))
    end

    for name in ["Np", "Tp", "a", "ap", "u", "v", "W", "cl", "cd", "F"]
        push!(partials_data, PartialsData(name, name, rows=rows, cols=cols, val=1.0))
    end

    # Check if the airfoil interpolation passed is a num_radial-length array.
    try
        num_af = length(af)
        if num_af == num_radial
            af = reshape(af, 1, num_radial)
        else
            throw(DomainError("af has length $num_af, but should have length $num_radial"))
        end
    catch e
        if isa(e, MethodError)
            # af is not an array of stuff, so assume it's just a single
            # function, and make it have shape (num_nodes, num_radial).
            af = fill(af, 1, num_radial)
        else
            # Some other error happened, so rethrow it.
            rethrow(e)
        end
    end

    return CCBladeResidualComp(num_nodes, num_radial, af, B, turbine, debug_print, input_data, output_data, partials_data)
end

function OpenMDAO.apply_nonlinear!(self::CCBladeResidualComp, inputs, outputs, residuals)
    # Airfoil interpolation object.
    af = self.af

    # Rotor parameters.
    B = self.B
    Rhub = inputs["Rhub"][1]
    Rtip = inputs["Rtip"][1]
    precone = inputs["precone"][1]
    turbine = self.turbine
    rotor = Rotor(Rhub, Rtip, B, turbine)

    # Blade section parameters.
    r = inputs["r"]
    chord = inputs["chord"]
    theta = inputs["theta"]
    sections = Section.(r, chord, theta, af)

    # Inflow parameters.
    Vx = inputs["Vx"]
    Vy = inputs["Vy"]
    rho = inputs["rho"]
    mu = inputs["mu"]
    asound = inputs["asound"]
    inflows = Inflow.(Vx, Vy, rho, mu, asound)

    phis = outputs["phi"]

    # Get the residual, and the outputs. The `out` variable is
    # two-dimensional array of length-two tuples. The first tuple
    # entry is the residual, and the second is the `Outputs`
    # struct.
    out = CCBlade.residual.(phis, sections, inflows, rotor)

    # Store the residual.
    @. residuals["phi"] = getindex(out, 1)

    # Get the other outputs.
    for o in self.outputs
        str = o.name
        sym = Symbol(str)
        @. residuals[str] = outputs[str] - getfield(getindex(out, 2), sym)
    end

    return nothing
end

function OpenMDAO.linearize!(self::CCBladeResidualComp, inputs, outputs, partials)
    num_nodes = self.num_nodes
    num_radial = self.num_radial
    # Airfoil interpolation object.
    af = self.af

    # Rotor parameters.
    Rhub = inputs["Rhub"][1]
    Rtip = inputs["Rtip"][1]
    precone = inputs["precone"][1]
    B = self.B
    turbine = self.turbine
    rotor = Rotor(Rhub, Rtip, B, turbine)

    # Blade section parameters.
    r = inputs["r"]
    chord = inputs["chord"]
    theta = inputs["theta"]
    sections = Section.(r, chord, theta, af)

    # Inflow parameters.
    Vx = inputs["Vx"]
    Vy = inputs["Vy"]
    rho = inputs["rho"]
    mu = inputs["mu"]
    asound = inputs["asound"]
    inflows = Inflow.(Vx, Vy, rho, mu, asound)

    # Phi, the implicit variable.
    phis = outputs["phi"]

    # Get the derivatives of the residual.
    residual_derivs = CCBlade.residual_partials.(phis, sections, inflows, rotor)

    # Copy the derivatives of the residual to the partials dict. First do the
    # derivative of the phi residual wrt phi.
    deriv = transpose(reshape(partials["phi", "phi"], (num_radial, num_nodes)))
    @. deriv = getfield(residual_derivs, :phi)

    # Copy the derivatives of the residual wrt each input.
    for i in self.inputs
        str = i.name
        sym = Symbol(str)
        deriv = transpose(reshape(partials["phi", str], (num_radial, num_nodes)))
        @. deriv = getfield(residual_derivs, sym)
    end

    # Get the derivatives of the explicit outputs.
    output_derivs = CCBlade.output_partials.(phis, sections, inflows, rotor)

    # Copy the derivatives of the explicit outputs into the partials dict.
    for o in self.outputs
        of_str = o.name
        if of_str == "phi"
            continue
        else
            of_sym = Symbol(of_str)
            for i in self.inputs
                wrt_str = i.name
                wrt_sym = Symbol(wrt_str)
                # reshape does not copy data: https://github.com/JuliaLang/julia/issues/112
                deriv = transpose(reshape(partials[of_str, wrt_str], (num_radial, num_nodes)))
                @. deriv = -getfield(getfield(output_derivs, of_sym), wrt_sym)
            end
            # Also need the derivative of each output with respect to phi, but
            # phi is an output, not an input, so we'll need to handle that
            # seperately.
            wrt_str = "phi"
            wrt_sym = :phi
            # reshape does not copy data: https://github.com/JuliaLang/julia/issues/112
            deriv = transpose(reshape(partials[of_str, wrt_str], (num_radial, num_nodes)))
            @. deriv = -getfield(getfield(output_derivs, of_sym), wrt_sym)
        end
    end

    return nothing
end

function OpenMDAO.solve_nonlinear!(self::CCBladeResidualComp, inputs, outputs)
    # Airfoil interpolation object.
    af = self.af

    # Rotor parameters.
    B = self.B
    Rhub = inputs["Rhub"][1]
    Rtip = inputs["Rtip"][1]
    precone = inputs["precone"][1]
    turbine = self.turbine
    rotor = Rotor(Rhub, Rtip, B, turbine)

    # Blade section parameters.
    r = inputs["r"]
    chord = inputs["chord"]
    theta = inputs["theta"]
    sections = Section.(r, chord, theta, af)

    # Inflow parameters.
    Vx = inputs["Vx"]
    Vy = inputs["Vy"]
    rho = inputs["rho"]
    mu = inputs["mu"]
    asound = inputs["asound"]
    inflows = Inflow.(Vx, Vy, rho, mu, asound)

    # When called this way, CCBlade.solve will return a 2D array of `Outputs`
    # objects.
    out = CCBlade.solve.(rotor, sections, inflows)

    # Set the outputs.
    @. outputs["phi"] = getfield(out, :phi)
    @. outputs["Np"] = getfield(out, :Np)
    @. outputs["Tp"] = getfield(out, :Tp)
    @. outputs["a"] = getfield(out, :a)
    @. outputs["ap"] = getfield(out, :ap)
    @. outputs["u"] = getfield(out, :u)
    @. outputs["v"] = getfield(out, :v)
    @. outputs["W"] = getfield(out, :W)
    @. outputs["cl"] = getfield(out, :cl)
    @. outputs["cd"] = getfield(out, :cd)
    @. outputs["F"] = getfield(out, :F)

    return nothing
end
