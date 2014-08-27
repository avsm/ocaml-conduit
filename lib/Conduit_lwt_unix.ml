(*
 * Copyright (c) 2012-2014 Anil Madhavapeddy <anil@recoil.org>
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

open Lwt
open Sexplib.Std
open Sexplib.Conv

type +'a io = 'a Lwt.t
type ic = Lwt_io.input_channel
type oc = Lwt_io.output_channel

type client = [
  | `OpenSSL of string * Ipaddr.t * int
  | `TCP of Ipaddr.t * int
  | `Unix_domain_socket of string
] with sexp

type server = [
  | `OpenSSL of
      [ `Crt_file_path of string ] * 
      [ `Key_file_path of string ] *
      [ `Password of bool -> string | `No_password ] *
      [ `Port of int ]
  | `TCP of [ `Port of int ]
  | `Unix_domain_socket of [ `File of string ]
] with sexp

type ctx = {
  src: Unix.sockaddr;
} 

type tcp_flow = {
  fd: Lwt_unix.file_descr sexp_opaque;
  ip: Ipaddr.t;
  port: int;
} with sexp

type domain_flow = {
  fd: Lwt_unix.file_descr sexp_opaque;
  path: string;
} with sexp

type flow =
  | TCP of tcp_flow
  | Domain_socket of domain_flow
  with sexp

let default_ctx =
  { src=Unix.(ADDR_INET (inet_addr_any,0)) }

let init ?src () =
  let open Unix in
  match src with
  | None ->
     return { src=(ADDR_INET (inet_addr_any, 0)) }
  | Some host ->
     Lwt_unix.getaddrinfo host "0" [AI_PASSIVE; AI_SOCKTYPE SOCK_STREAM]
     >>= function
     | {ai_addr;_}::_ -> return { src=ai_addr }
     | [] -> fail (Failure "Invalid conduit source address specified")

let connect ~ctx (mode:client) =
  print_endline (Sexplib.Sexp.to_string_hum (sexp_of_client mode));
  match mode with
  | `OpenSSL (_host, ip, port) -> 
IFDEF HAVE_LWT_SSL THEN
      let sa = Unix.ADDR_INET (Ipaddr_unix.to_inet_addr ip,port) in
      lwt fd, ic, oc = Conduit_lwt_unix_net_ssl.Client.connect ~src:ctx.src sa in
      let flow = TCP {fd;ip;port} in
      return (flow, ic, oc)
ELSE
      fail (Failure "No SSL support compiled into Conduit")
END
  | `TCP (ip,port) ->
       let sa = Unix.ADDR_INET (Ipaddr_unix.to_inet_addr ip, port) in
       lwt fd,ic,oc = Conduit_lwt_unix_net.Sockaddr_client.connect ~src:ctx.src sa in
       let flow = TCP {fd;ip;port} in
       return (flow, ic, oc)
  | `Unix_domain_socket path ->
       lwt (fd,ic,oc) = Conduit_lwt_unix_net.Sockaddr_client.connect (Unix.ADDR_UNIX path) in
       let flow = Domain_socket {fd; path} in
       return (flow, ic, oc)

let sockaddr_on_tcp_port ctx port =
  let open Unix in
  match ctx.src with
  | ADDR_UNIX _ -> raise (Failure "Cant listen to TCP on a domain socket")
  | ADDR_INET (a,_) -> (ADDR_INET (a,port), Ipaddr_unix.of_inet_addr a)

let serve ?timeout ?stop ~(ctx:ctx) ~(mode:server) callback =
  match mode with
  | `TCP (`Port port) ->
       let sockaddr, ip = sockaddr_on_tcp_port ctx port in 
       Conduit_lwt_unix_net.Sockaddr_server.init ~sockaddr ?timeout ?stop
         (fun fd ic oc -> callback (TCP {fd; ip; port}) ic oc)
  |  `Unix_domain_socket (`File path) ->
       let sockaddr = Unix.ADDR_UNIX path in
       Conduit_lwt_unix_net.Sockaddr_server.init ~sockaddr ?timeout ?stop
         (fun fd ic oc -> callback (Domain_socket {fd;path}) ic oc)
  | `OpenSSL (`Crt_file_path certfile, `Key_file_path keyfile, pass, `Port port) -> 
IFDEF HAVE_LWT_SSL THEN
       let sockaddr, ip = sockaddr_on_tcp_port ctx port in
       let password = match pass with |`No_password -> None |`Password fn -> Some fn in
       Conduit_lwt_unix_net_ssl.Server.init ?password ~certfile ~keyfile ?timeout ?stop sockaddr
         (fun fd ic oc -> callback (TCP {fd;ip;port}) ic oc)
ELSE
       fail (Failure "No SSL support compiled into Conduit")
END

type endp = [
  | `TCP of Ipaddr.t * int        (** IP address and destination port *)
  | `Unix_domain_socket of string (** Unix domain file path *)
  | `Vchan of string list         (** Xenstore path *)
  | `TLS of string * endp         (** Wrap in a TLS channel, [hostname,endp] *)
  | `Unknown of string            (** Failed resolution *)
] with sexp

(** Use the configuration of the server to interpret how to
    handle a particular endpoint from the resolver into a
    concrete implementation of type [client] *)
let endp_to_client ~ctx (endp:Conduit.endp) =
  match endp with
  | `TCP (_ip, _port) as mode -> return mode
  | `Unix_domain_socket _path as mode -> return mode
  | `TLS (host, `TCP (ip, port)) -> return (`OpenSSL (host, ip, port))
  | `TLS (_host, _) -> fail (Failure "TLS to non-TCP currently unsupported")
  | `Vchan _path -> fail (Failure "VChan not supported")
  | `Unknown err -> fail (Failure ("resolution failed: " ^ err))
