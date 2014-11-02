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

(** Connection establishment using the
    {{:http://ocsigen.org/lwt/api/Lwt_unix}Lwt_unix} library *) 

open Sexplib.Conv

(** Set of supported client connections that are supported by this module. *)
type client = [
  | `OpenSSL of string * Ipaddr.t * int (** Use OpenSSL to connect to the given [host], [ip], [port] tuple via TCP *)
  | `TCP of Ipaddr.t * int (** Use TCP to connect to the given [ip], [port] tuple. *)
  | `Unix_domain_socket of string (** Use UNIX domain sockets to connect to a socket on the [path]. *)
  | `Vchan_direct of int * string (** Connect to the remote VM on the [domid], [port] tuple. *)
  | `Vchan_domain_socket of string * string
] with sexp

(** Set of supported listening mechanisms that are supported by this module. *)
type server = [
  | `OpenSSL of
      [ `Crt_file_path of string ] *
      [ `Key_file_path of string ] *
      [ `Password of bool -> string | `No_password ] *
      [ `Port of int ]
  | `TCP of [ `Port of int ]
  | `Unix_domain_socket of [ `File of string ]
  | `Vchan_direct of int * string
  | `Vchan_domain_socket of string  * string
] with sexp

type 'a io = 'a Lwt.t
type ic = Lwt_io.input_channel
type oc = Lwt_io.output_channel

type tcp_flow = private {
  fd: Lwt_unix.file_descr sexp_opaque;
  ip: Ipaddr.t;
  port: int;
} with sexp_of

type domain_flow = private {
  fd: Lwt_unix.file_descr sexp_opaque;
  path: string;
} with sexp_of

type vchan_flow = private {
  domid: int;
  port: string;
} with sexp_of

type flow = private
  | TCP of tcp_flow
  | Domain_socket of domain_flow
  | Vchan of vchan_flow
with sexp_of

(** Type describing where to locate an OpenSSL-format
    key in the filesystem *)
type tls_server_key = [
 | `None
 | `OpenSSL of
    [ `Crt_file_path of string ] *
    [ `Key_file_path of string ] *
    [ `Password of bool -> string | `No_password ]
]

(** State handler for an active conduit *)
type ctx

(** Default context that listens on all source addresses with
    no TLS certificate associated with the Conduit *)
val default_ctx : ctx

(** [init ?src ?tls_server_key] will initialize a Unix conduit
    that binds to the [src] interface if specified.  If TLS server
    connections are used, then [tls_server_key] must contain a
    valid certificate to be used to advertise a TLS connection *)
val init : ?src:string -> ?tls_server_key:tls_server_key -> unit -> ctx io

(** [connect ~ctx client] establishes an outgoing connection
    via the [ctx] context to the endpoint described by [client] *)
val connect : ctx:ctx -> client -> (flow * ic * oc) io

(** [serve ?timeout ?stop ~ctx ~mode fn] establishes a listening
    connection of type [mode], using the [ctx] context.  The
    [stop] thread will terminate the server if it ever becomes
    determined.  Every connection will be served in a new
    lightweight thread that is invoked via the [fn] callback *)
val serve :
  ?timeout:int -> ?stop:(unit io) -> ctx:ctx ->
   mode:server -> (flow -> ic -> oc -> unit io) -> unit io

(** [endp_of_flow flow] retrieves the original {!Conduit.endp}
    from the established [flow] *)
val endp_of_flow : flow -> Conduit.endp

(** [endp_to_client ~ctx endp] converts an [endp] into a
    a concrete connection mechanism of type [client] *)
val endp_to_client : ctx:ctx -> Conduit.endp -> client io

(** [endp_to_server ~ctx endp] converts an [endp] into a
    a concrete connection mechanism of type [client] *)
val endp_to_server : ctx:ctx -> Conduit.endp -> server io
