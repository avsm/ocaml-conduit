(*
 * Copyright (c) 2012-2014 Anil Madhavapeddy <anil@recoil.org>
 * Copyright (c) 2014 Clark Gaebel
 *
 * Permission to use, copy, modify, and distribute this software for any
 * purpose with or without fee is hereby granted, provided that the above
 * copyright notice and this permission notice appear in all copies.
 *
 * THE SOFTWARE IS PROVIDED "AS IS" AND THE AUTHOR DISCLAIMS ALL WARRANTIES
 * WITH REGARD TO THIS SOFTWARE INCLUDING ALL IMPLIED WARRANTIES OF
 * MERCHANTABILITY AND FITNESS. IN NO EVENT SHALL THE AUTHOR BE LIABLE FOR
 * ANY SPECIAL, DIRECT, INDIRECT, OR CONSEQUENTIAL DAMAGES OR ANY DAMAGES
 * WHATSOEVER RESULTING FROM LOSS OF USE, DATA OR PROFITS, WHETHER IN AN
 * ACTION OF CONTRACT, NEGLIGENCE OR OTHER TORTIOUS ACTION, ARISING OUT OF
 * OR IN CONNECTION WITH THE USE OR PERFORMANCE OF THIS SOFTWARE.
 *
*)

open Core.Std
open Async.Std
open Async_ssl.Std

let ssl_connect ?version ?name ?ca_file ?ca_path ?session ?verify
                net_to_ssl ssl_to_net =
  let net_to_ssl = Reader.pipe net_to_ssl in
  let ssl_to_net = Writer.pipe ssl_to_net in
  let app_to_ssl, app_wr = Pipe.create () in
  let app_rd, ssl_to_app = Pipe.create () in
  let client =  Ssl.client ?version ?name ?ca_file ?ca_path ?session ~app_to_ssl ~ssl_to_app ~net_to_ssl ~ssl_to_net () in
  let verify_connection = match verify with
    | None -> fun _ -> return true
    | Some f -> f
  in
  client >>= function
  | Error err -> Error.raise err
  | Ok con -> verify_connection con
  >>= function
  | false -> failwith "Connection verification failed."
  | true ->
  Reader.of_pipe (Info.of_string "async_conduit_ssl_reader") app_rd
  >>= fun app_rd ->
  Writer.of_pipe (Info.of_string "async_conduit_ssl_writer") app_wr
  >>| fun (app_wr,_) ->
  app_rd, app_wr

let ssl_listen ?(version=Ssl.Version.Tlsv1_2) ?ca_file ?ca_path ~crt_file ~key_file rd wr =
  let net_to_ssl = Reader.pipe rd in
  let ssl_to_net = Writer.pipe wr in
  let app_to_ssl, app_wr = Pipe.create () in
  let app_rd, ssl_to_app = Pipe.create () in
  let server = Ssl.server
    ?ca_file
    ?ca_path
    ~version
    ~crt_file
    ~key_file
    ~app_to_ssl
    ~ssl_to_app
    ~net_to_ssl
    ~ssl_to_net
    ()
  in
  don't_wait_for (server >>= fun _con -> return ());
  Reader.of_pipe (Info.of_string "async_conduit_ssl_reader") app_rd
  >>= fun app_rd ->
  Writer.of_pipe (Info.of_string "async_conduit_ssl_writer") app_wr
  >>| fun (app_wr,_) ->
  (* Close the pipes we created for ssl when we're done! *)
  don't_wait_for (
    Pipe.closed net_to_ssl >>= fun () ->
    Deferred.all_ignore [Writer.close app_wr; Reader.close app_rd]
  );
  app_rd, app_wr
