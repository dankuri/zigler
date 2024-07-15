defmodule Zig.Compiler do
  @moduledoc """
  handles instrumenting elixir code with hooks for zig NIFs.
  """

  require Logger

  alias Zig.Attributes
  alias Zig.Builder
  alias Zig.Command
  alias Zig.EasyC
  alias Zig.Manifest
  alias Zig.Nif
  alias Zig.Parser
  alias Zig.Sema

  defmacro __before_compile__(%{module: module, file: file} = env) do
    # NOTE: this is going to be called only from Elixir.  Erlang will not call this.
    # all functionality in this macro must be replicated when running compilation from
    # erlang.

    opts =
      module
      |> Module.get_attribute(:zigler_opts)
      |> Map.replace!(:attributes, Attributes.from_module(module))
      |> adjust_elixir_options

    code_dir = opts.dir || Path.dirname(file)

    code =
      cond do
        opts.easy_c ->
          if match?({:auto, _}, opts.nifs) do
            raise CompileError,
              file: file,
              line: env.line,
              description: "easy-c mode cannot have automatically detected nifs"
          end

          EasyC.build_from(opts)

        path = opts.zig_code_path ->
          # check for existence of :zig_code_parts
          unless [] == Module.get_attribute(module, :zig_code_parts) do
            raise CompileError,
              file: file,
              line: env.line,
              description:
                "(module #{inspect(module)}) you may not use ~Z when `:zig_code_path` is specified"
          end

          env.file
          |> Path.dirname()
          |> Path.join(path)
          |> File.read!()

        :else ->
          module
          |> Module.get_attribute(:zig_code_parts)
          |> Enum.reverse()
          |> then(
            &[
              "// this code is autogenerated, do not check it into to your code repository\n\n"
              | &1
            ]
          )
          |> IO.iodata_to_binary()
      end

    code
    |> compile(code_dir, opts)
    |> Zig.Macro.inspect(opts)
  end

  defp adjust_elixir_options(opts) do
    Map.update!(opts, :nifs, &nif_substitution/1)
  end

  # if the elixir `nif` option contains `...` then this should be converted 
  # into `{:auto, <other_options>}`.  Also, if the nif entry is just an atom,
  # converts that entry into `{nif, []}`
  #
  # This function will reverse the list, but since order doesn't matter for this 
  # option, it is okay.
  defp nif_substitution(:auto), do: {:auto, []}

  defp nif_substitution({:auto, list}), do: {:auto, Enum.map(list, &decode_params/1)}

  defp nif_substitution(opts) do
    case Enum.reduce(opts, [], fn
           {:..., _, _}, {:auto, _} = so_far -> so_far
           {:..., _, _}, list -> {:auto, list}
           other, so_far -> prepend_nif(so_far, other)
         end) do
      {:auto, list} -> {:auto, Enum.map(list, &decode_params/1)}
      list -> Enum.map(list, &decode_params/1)
    end
  end

  defp prepend_nif({:auto, so_far}, nif_name) when is_atom(nif_name),
    do: {:auto, [{nif_name, []} | so_far]}

  defp prepend_nif(so_far, nif_name) when is_atom(nif_name), do: [{nif_name, []} | so_far]
  defp prepend_nif({:auto, so_far}, nif_info), do: {:auto, [nif_info | so_far]}
  defp prepend_nif(so_far, nif_info), do: [nif_info | so_far]

  defp decode_params({nif, opts}) do
    {nif, decode_params(opts)}
  end

  defp decode_params([{:params, params_ast} | rest]) do
    [{:params, maybe_from_ast(params_ast)} | rest]
  end

  defp decode_params([other | rest]), do: [other | decode_params(rest)]
  defp decode_params([]), do: []

  # adjust nif parameters if they came from elixir as an AST
  defp maybe_from_ast({:%{}, _, ast}), do: Enum.into(ast, %{})
  defp maybe_from_ast(other) when is_map(other), do: other

  def before_compile_erlang(module, {file, line}, opts) do
    opts
    |> Keyword.merge(language: :erlang)
    |> Keyword.update(:nifs, {:auto, []}, &nif_substitution/1)
    |> Zig.Module.new(%{module: module, file: file, line: line})
  end

  # note that this function is made public so that it can be both accessed
  # from the :zigler entrypoint for erlang parse transforms, as well as the
  # __before_compile__ entrypoint for Elixir
  def compile(zig_code, code_dir, opts) do
    zig_code_path = Path.join(code_dir, ".#{opts.module}.zig")

    opts
    |> Map.replace!(:zig_code_path, zig_code_path)
    |> tap(&write_code!(&1, zig_code))
    |> Builder.stage()
    |> Manifest.create(zig_code)
    |> Sema.run_sema!()
    |> apply_parser(zig_code)
    |> Sema.analyze_file!()
    |> verify_nifs_exist()
    |> add_nif_resources()
    |> bind_documentation()
    |> tap(&precompile/1)
    |> Command.compile!()
    |> Manifest.unload()
    |> elixir_save_zigler_opts()
    |> case do
      %{language: Elixir} = module ->
        Zig.Module.render_elixir(module, zig_code)

      %{language: :erlang} = module ->
        Zig.Module.render_erlang(module, zig_code)
    end
  end

  defp write_code!(module, zig_code) do
    File.write!(module.zig_code_path, zig_code)
  end

  defp apply_parser(module, zig_code) do
    parsed = Parser.parse(zig_code)

    external_resources =
      parsed
      |> recursive_resource_search(module.file, MapSet.new())
      |> Enum.to_list()

    %{module | parsed: parsed, external_resources: external_resources}
  end

  defp precompile(module) do
    path =
      module.module
      |> Builder.staging_directory()
      |> Path.join("module.zig")

    File.write!(path, Zig.Module.render_zig(module))
    Command.fmt(path)

    Logger.debug("wrote module code to #{path}")
  end

  defp recursive_resource_search(parsed, path, so_far) do
    Enum.reduce(parsed.dependencies, so_far, fn dep, so_far ->
      dep_path =
        dep
        |> Path.expand(Path.dirname(path))
        |> Path.relative_to_cwd()

      if dep_path in so_far do
        so_far
      else
        dep_path
        |> File.read!()
        |> Parser.parse()
        |> recursive_resource_search(dep_path, MapSet.put(so_far, dep_path))
      end
    end)
  end

  #############################################################################
  ## STEPS

  def assembly_dir(env, module) do
    System.tmp_dir()
    |> String.replace("\\", "/")
    |> Path.join(".zigler_compiler/#{env}/#{module}")
  end

  defp verify_nifs_exist(module) do
    if module.nifs == [] do
      raise CompileError, description: "no nifs found in module.", file: module.file
    end

    module
  end

  defp add_nif_resources(module) do
    # some nifs (threaded, yielding) must use their own resources to work correctly.
    # this adds those resources to the list.
    nif_resources = Enum.flat_map(module.nifs, &Nif.resources/1)

    %{module | resources: module.resources ++ nif_resources}
  end

  defp bind_documentation(module) do
    Map.update!(module, :nifs, fn nifs ->
      Enum.map(nifs, &bind_nif_documentation(&1, module.parsed.code))
    end)
  end

  defp bind_nif_documentation(%{name: name} = nif, code) do
    Map.replace!(nif, :doc, Enum.find_value(code, &doc_if_name(&1, name)))
  end

  defp doc_if_name(%{name: name, doc_comment: comment}, name),
    do: if(comment, do: String.trim(comment))

  defp doc_if_name(_, _), do: nil

  defp elixir_save_zigler_opts(%{language: Elixir} = opts) do
    Module.put_attribute(opts.module, :zigler_opts, opts)
    opts
  end

  defp elixir_save_zigler_opts(opts), do: opts
end
