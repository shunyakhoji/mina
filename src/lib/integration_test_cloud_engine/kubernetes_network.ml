open Core
open Async
open Integration_test_lib

(* exclude from bisect_ppx to avoid type error on GraphQL modules *)
[@@@coverage exclude_file]

module Node = struct
  type t =
    {cluster: string; namespace: string; pod_id: string; node_graphql_port: int}

  let id {pod_id; _} = pod_id

  let base_kube_args t = ["--cluster"; t.cluster; "--namespace"; t.namespace]

  let node_to_string (n : t) : String.t =
    Format.sprintf
      "{cluster: %s; namespace: %s; pod_id: %s; node_graphql_port: %d}"
      n.cluster n.namespace n.pod_id n.node_graphql_port

  let node_list_to_string (nl : t list) : String.t =
    Format.sprintf "[ %s ]"
      (String.concat ~sep:",  " (List.map nl ~f:node_to_string))

  let run_in_container node cmd =
    let base_args = base_kube_args node in
    let base_kube_cmd = "kubectl " ^ String.concat ~sep:" " base_args in
    let kubectl_cmd =
      Printf.sprintf
        "%s -c coda exec -i $( %s get pod -l \"app=%s\" -o name) -- %s"
        base_kube_cmd base_kube_cmd node.pod_id cmd
    in
    let%bind cwd = Unix.getcwd () in
    let%map _ = Cmd_util.run_cmd_exn cwd "sh" ["-c"; kubectl_cmd] in
    ()

  let start ~fresh_state node : unit Malleable_error.t =
    let open Malleable_error.Let_syntax in
    let%bind () =
      if fresh_state then
        Deferred.bind ~f:Malleable_error.return
          (run_in_container node "rm -rf .coda-config")
      else Malleable_error.return ()
    in
    Deferred.bind ~f:Malleable_error.return
      (run_in_container node "./start.sh")

  let stop node =
    Deferred.bind ~f:Malleable_error.return (run_in_container node "./stop.sh")

  let get_pod_name t : string Malleable_error.t =
    let args =
      List.append (base_kube_args t)
        [ "get"
        ; "pod"
        ; "-l"
        ; sprintf "app=%s" t.pod_id
        ; "-o=custom-columns=NAME:.metadata.name"
        ; "--no-headers" ]
    in
    let%bind run_result =
      Deferred.bind ~f:Malleable_error.of_or_error_hard
        (Process.run_lines ~prog:"kubectl" ~args ())
    in
    match run_result with
    | Ok
        { Malleable_error.Accumulator.computation_result= [pod_name]
        ; soft_errors= _ } ->
        Malleable_error.return pod_name
    | Ok {Malleable_error.Accumulator.computation_result= []; soft_errors= _}
      ->
        Malleable_error.of_string_hard_error "get_pod_name: no result"
    | Ok _ ->
        Malleable_error.of_string_hard_error "get_pod_name: too many results"
    | Error
        { Malleable_error.Hard_fail.hard_error= e
        ; Malleable_error.Hard_fail.soft_errors= _ } ->
        Malleable_error.of_error_hard e.error

  let set_port_forwarding ~logger t ~remote_port ~local_port =
    let open Malleable_error.Let_syntax in
    let%bind name = get_pod_name t in
    let portmap = sprintf "%d:%d" remote_port local_port in
    let args =
      List.append (base_kube_args t) ["port-forward"; name; portmap]
    in
    [%log debug] "Port forwarding using \"kubectl %s\"\n"
      String.(concat args ~sep:" ") ;
    let%bind proc =
      Deferred.bind ~f:Malleable_error.of_or_error_hard
        (Process.create ~prog:"kubectl" ~args ())
    in
    Exit_handlers.register_handler ~logger
      ~description:
        (sprintf "Kubectl port forwarder on pod %s, port %d" t.pod_id
           local_port) (fun () ->
        [%log debug]
          "Port forwarding being killed, no longer occupying port %d "
          local_port ;
        ignore Signal.(send kill (`Pid (Process.pid proc))) ) ;
    Deferred.bind ~f:Malleable_error.of_or_error_hard
      (Process.collect_stdout_and_wait proc)

  let set_port_forwarding_exn ~logger t ~remote_port ~local_port =
    match%map.Deferred.Let_syntax
      set_port_forwarding ~logger t ~remote_port ~local_port
    with
    | Ok _ ->
        (* not reachable, port forwarder does not terminate *)
        ()
    | Error {Malleable_error.Hard_fail.hard_error= err; soft_errors= _} ->
        [%log fatal] "Error running k8s port forwarding"
          ~metadata:[("error", Error_json.error_to_yojson err.error)] ;
        failwith "Could not run k8s port forwarding"

  module Decoders = Graphql_lib.Decoders

  module Graphql = struct
    (* queries on localhost because of port forwarding *)
    let uri port =
      Uri.make
        ~host:Unix.Inet_addr.(localhost |> to_string)
        ~port ~path:"graphql" ()

    let set_port_forwarding_exn ~logger t =
      set_port_forwarding_exn ~logger t ~remote_port:t.node_graphql_port
        ~local_port:t.node_graphql_port

    module Client = Graphql_lib.Client.Make (struct
      let preprocess_variables_string = Fn.id

      let headers = String.Map.empty
    end)

    module Unlock_account =
    [%graphql
    {|
      mutation ($password: String!, $public_key: PublicKey!) {
        unlockAccount(input: {password: $password, publicKey: $public_key }) {
          public_key: publicKey @bsDecoder(fn: "Decoders.public_key")
        }
      }
    |}]

    module Send_payment =
    [%graphql
    {|
      mutation ($sender: PublicKey!,
      $receiver: PublicKey!,
      $amount: UInt64!,
      $token: UInt64,
      $fee: UInt64!,
      $nonce: UInt32,
      $memo: String) {
        sendPayment(input:
          {from: $sender, to: $receiver, amount: $amount, token: $token, fee: $fee, nonce: $nonce, memo: $memo}) {
            payment {
              id
            }
          }
      }
    |}]

    module Get_balance =
    [%graphql
    {|
      query ($public_key: PublicKey, $token: UInt64) {
        account(publicKey: $public_key, token: $token) {
          balance {
            total @bsDecoder(fn: "Decoders.balance")
          }
        }
      }
    |}]

    module Query_peer_id =
    [%graphql
    {|
      query {
        daemonStatus {
          addrsAndPorts {
            peer {
              peerId
            }
          }
          peers {  peerId }

        }
      }
    |}]
  end

  module Postgresql = struct
    let port = 5432

    let set_port_forwarding_exn ~logger t =
      set_port_forwarding_exn ~logger t ~remote_port:port ~local_port:port
  end

  (* this function will repeatedly attempt to connect to graphql port <num_tries> times before giving up *)
  let exec_graphql_request ?(num_tries = 10) ?(retry_delay_sec = 30.0)
      ?(initial_delay_sec = 30.0) ~logger ~graphql_port
      ?(retry_on_graphql_error = false) ~query_name query_obj =
    let open Malleable_error.Let_syntax in
    [%log info]
      "exec_graphql_request, Will now attempt to make GraphQL request: %s"
      query_name ;
    let err_str str = sprintf "%s: %s" query_name str in
    let rec retry n =
      if n <= 0 then (
        let err_str = err_str "too many tries" in
        [%log fatal] "%s" err_str ;
        Malleable_error.of_string_hard_error err_str )
      else
        match%bind
          Deferred.bind ~f:Malleable_error.return
            ((Graphql.Client.query query_obj) (Graphql.uri graphql_port))
        with
        | Ok result ->
            let err_str = err_str "succeeded" in
            [%log info] "exec_graphql_request %s" err_str ;
            return result
        | Error (`Failed_request err_string) ->
            let err_str =
              err_str
                (sprintf
                   "exec_graphql_request, Failed GraphQL request: %s, %d \
                    tries left"
                   err_string (n - 1))
            in
            [%log warn] "%s" err_str ;
            let%bind () =
              Deferred.bind ~f:Malleable_error.return
                (after (Time.Span.of_sec retry_delay_sec))
            in
            retry (n - 1)
        | Error (`Graphql_error err_string) ->
            let err_str =
              err_str
                (sprintf "exec_graphql_request, GraphQL error: %s" err_string)
            in
            [%log error] "%s" err_str ;
            if retry_on_graphql_error then (
              let%bind () =
                Deferred.bind ~f:Malleable_error.return
                  (after (Time.Span.of_sec retry_delay_sec))
              in
              [%log debug]
                "exec_graphql_request, After GraphQL error, %d tries left"
                (n - 1) ;
              retry (n - 1) )
            else Malleable_error.of_string_hard_error err_string
    in
    let%bind () =
      Deferred.bind ~f:Malleable_error.return
        (after (Time.Span.of_sec initial_delay_sec))
    in
    retry num_tries

  let get_peer_id ~logger t =
    let open Malleable_error.Let_syntax in
    [%log info] "Getting node's peer_id, and the peer_ids of node's peers"
      ~metadata:
        [("namespace", `String t.namespace); ("pod_id", `String t.pod_id)] ;
    Deferred.don't_wait_for (Graphql.set_port_forwarding_exn ~logger t) ;
    let query_obj = Graphql.Query_peer_id.make () in
    let%bind query_result_obj =
      exec_graphql_request ~logger ~graphql_port:t.node_graphql_port
        ~retry_on_graphql_error:true ~query_name:"query_peer_id" query_obj
    in
    [%log info] "get_peer_id, finished exec_graphql_request" ;
    let self_id_obj = ((query_result_obj#daemonStatus)#addrsAndPorts)#peer in
    let%bind self_id =
      match self_id_obj with
      | None ->
          Malleable_error.of_string_hard_error "Peer not found"
      | Some peer ->
          Malleable_error.return peer#peerId
    in
    let peers = (query_result_obj#daemonStatus)#peers |> Array.to_list in
    let peer_ids = List.map peers ~f:(fun peer -> peer#peerId) in
    [%log info]
      "get_peer_id, result of graphql querry (self_id,[peers]) (%s,%s)" self_id
      (String.concat ~sep:" " peer_ids) ;
    return (self_id, peer_ids)

  let get_balance ~logger t ~account_id =
    let open Malleable_error.Let_syntax in
    [%log info] "Getting account balance"
      ~metadata:
        [ ("namespace", `String t.namespace)
        ; ("pod_id", `String t.pod_id)
        ; ("account_id", Mina_base.Account_id.to_yojson account_id) ] ;
    Deferred.don't_wait_for (Graphql.set_port_forwarding_exn ~logger t) ;
    let pk = Mina_base.Account_id.public_key account_id in
    let token = Mina_base.Account_id.token_id account_id in
    let get_balance () =
      let get_balance_obj =
        Graphql.Get_balance.make
          ~public_key:(Graphql_lib.Encoders.public_key pk)
          ~token:(Graphql_lib.Encoders.token token)
          ()
      in
      let%bind balance_obj =
        exec_graphql_request ~logger ~graphql_port:t.node_graphql_port
          ~retry_on_graphql_error:true ~query_name:"get_balance_graphql"
          get_balance_obj
      in
      match balance_obj#account with
      | None ->
          Malleable_error.of_string_hard_error
            (sprintf
               !"Account with %{sexp:Mina_base.Account_id.t} not found"
               account_id)
      | Some acc ->
          Malleable_error.return (acc#balance)#total
    in
    get_balance ()

  (* if we expect failure, might want retry_on_graphql_error to be false *)
  let send_payment ?(retry_on_graphql_error = true) ~logger t ~sender ~receiver
      ~amount ~fee =
    [%log info] "Sending a payment"
      ~metadata:
        [("namespace", `String t.namespace); ("pod_id", `String t.pod_id)] ;
    Deferred.don't_wait_for (Graphql.set_port_forwarding_exn ~logger t) ;
    let open Malleable_error.Let_syntax in
    let sender_pk_str = Signature_lib.Public_key.Compressed.to_string sender in
    [%log info] "send_payment: unlocking account"
      ~metadata:[("sender_pk", `String sender_pk_str)] ;
    let unlock_sender_account_graphql () =
      let unlock_account_obj =
        Graphql.Unlock_account.make ~password:"naughty blue worm"
          ~public_key:(Graphql_lib.Encoders.public_key sender)
          ()
      in
      exec_graphql_request ~logger ~graphql_port:t.node_graphql_port
        ~query_name:"unlock_sender_account_graphql" unlock_account_obj
    in
    let%bind _ = unlock_sender_account_graphql () in
    let send_payment_graphql () =
      let send_payment_obj =
        Graphql.Send_payment.make
          ~sender:(Graphql_lib.Encoders.public_key sender)
          ~receiver:(Graphql_lib.Encoders.public_key receiver)
          ~amount:(Graphql_lib.Encoders.amount amount)
          ~fee:(Graphql_lib.Encoders.fee fee)
          ()
      in
      (* retry_on_graphql_error=true because the node might be bootstrapping *)
      exec_graphql_request ~logger ~graphql_port:t.node_graphql_port
        ~retry_on_graphql_error ~query_name:"send_payment_graphql"
        send_payment_obj
    in
    let%map sent_payment_obj = send_payment_graphql () in
    let (`UserCommand id_obj) = (sent_payment_obj#sendPayment)#payment in
    let user_cmd_id = id_obj#id in
    [%log info] "Sent payment"
      ~metadata:[("user_command_id", `String user_cmd_id)] ;
    ()

  let dump_archive_data ~logger (t : t) ~data_file =
    [%log info] "Setup port forwarding for Postgresql" ;
    Deferred.don't_wait_for (Postgresql.set_port_forwarding_exn ~logger t) ;
    [%log info] "Collecting archive data" ;
    let args = ["--create"; "--no-owner"; "--dbname"; "archiver"] in
    let%bind.Deferred.Let_syntax () = after (Time.Span.of_sec 5.) in
    let%map.Malleable_error.Let_syntax sql_lines =
      let%bind.Deferred.Let_syntax sql_lines_or_error =
        Process.run_lines ~prog:"pg_dump" ~args ()
      in
      Malleable_error.of_or_error_hard sql_lines_or_error
    in
    [%log info] "Dumping archive data to file %s" data_file ;
    Out_channel.with_file data_file ~f:(fun out_ch ->
        Out_channel.output_lines out_ch sql_lines )
end

type t =
  { namespace: string
  ; constants: Test_config.constants
  ; block_producers: Node.t list
  ; snark_coordinators: Node.t list
  ; archive_nodes: Node.t list
  ; testnet_log_filter: string
  ; keypairs: Signature_lib.Keypair.t list
  ; nodes_by_app_id: Node.t String.Map.t }

let constants {constants; _} = constants

let constraint_constants {constants; _} = constants.constraints

let genesis_constants {constants; _} = constants.genesis

let block_producers {block_producers; _} = block_producers

let snark_coordinators {snark_coordinators; _} = snark_coordinators

let archive_nodes {archive_nodes; _} = archive_nodes

let keypairs {keypairs; _} = keypairs

let all_nodes {block_producers; snark_coordinators; archive_nodes; _} =
  block_producers @ snark_coordinators @ archive_nodes

let lookup_node_by_app_id t = Map.find t.nodes_by_app_id
