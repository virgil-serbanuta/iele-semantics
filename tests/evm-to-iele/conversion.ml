open Evm
open Iele

let _2 = Z.of_int 2
let _31 = Z.of_int 31
let _32 = Z.of_int 32
let _256 = Z.of_int 256
let _65536 = Z.of_int 65536
let pow256 = Z.shift_left Z.one 256
let _mask = Z.sub pow256 Z.one

let compatibility = true

let rec preprocess_evm (evm: evm_op list) : intermediate_op list = match evm with
| [] -> []
| `SDIV :: tl -> `DIV :: preprocess_evm tl
| `SMOD :: tl -> `MOD :: preprocess_evm tl
| (`DIV | `MOD | `GT | `LT as op) :: tl when compatibility -> `PUSH(_32) :: `TWOS :: `SWAP(1) :: `PUSH(_32) :: `TWOS :: `SWAP(1) :: op :: preprocess_evm tl
| (`ADDMOD | `MULMOD as op) :: tl when compatibility -> `PUSH(_32) :: `TWOS :: `SWAP(1) :: `PUSH(_32) :: `TWOS :: `SWAP(1) :: `SWAP(2) :: `PUSH(_32) :: `TWOS :: `SWAP(2) :: op :: preprocess_evm tl
| `SLT :: tl -> `LT :: preprocess_evm tl
| `SGT :: tl -> `GT :: preprocess_evm tl
| (`JUMP|`JUMPI) :: tl -> `INVALID :: preprocess_evm tl
| `PUSH(_,pc) :: `JUMP :: tl when Z.lt pc _65536 -> `JUMP(Z.to_int pc) :: preprocess_evm tl
| `PUSH(_,pc) :: `JUMPI :: tl when Z.lt pc _65536 -> `JUMPI(Z.to_int pc) :: preprocess_evm tl
| `PC(pc) :: `JUMP :: tl when compatibility && pc < 65536 -> `JUMP(pc) :: preprocess_evm tl
| `PC(pc) :: `JUMPI :: tl when compatibility && pc < 65536 -> `JUMPI(pc) :: preprocess_evm tl
| `PUSH(_,byte) :: `SIGNEXTEND :: tl -> `PUSH(Z.min byte _31) :: `SIGNEXTEND :: preprocess_evm tl
| _ :: (`JUMP|`JUMPI) :: _ -> failwith "dynamic jumps detected"
| `PUSH(n,v) :: op2 :: tl -> `PUSH(v) :: preprocess_evm (op2 :: tl)
| `PUSH(n,v) :: [] -> `PUSH(v) :: []
| `PC(pc) :: tl when compatibility -> `PUSH(Z.of_int pc) :: preprocess_evm tl
| `PC(_) :: tl -> `PC :: preprocess_evm tl
| `LOG(_) | `CALL | `CALLCODE | `DELEGATECALL | `STATICCALL | `EXTCODECOPY | `CODECOPY | `CALLDATACOPY | `RETURNDATACOPY
| `RETURN | `REVERT | `SSTORE | `ADDMOD | `MULMOD | `CREATE | `POP | `SELFDESTRUCT | `MSTORE | `MSTORE8 | `ADD | `MUL 
| `SUB | `DIV | `EXP | `MOD | `BYTE | `SIGNEXTEND | `AND | `OR | `XOR | `LT | `GT | `EQ | `SHA3 | `SWAP(_) | `INVALID
| `STOP | `MLOAD | `ISZERO | `NOT | `BLOCKHASH | `CALLDATALOAD | `BALANCE | `EXTCODESIZE | `SLOAD | `DUP(_)
| `GAS | `GASPRICE | `GASLIMIT | `COINBASE | `TIMESTAMP | `NUMBER | `DIFFICULTY | `ADDRESS | `ORIGIN | `CALLER 
| `CALLVALUE | `MSIZE | `CODESIZE | `CALLDATASIZE | `RETURNDATASIZE | `JUMPDEST _ as op :: tl-> op :: preprocess_evm tl

let rec set_nth l i v = match i with
| 0 -> v :: List.tl l
| _ -> (List.hd l) :: set_nth (List.tl l) (i-1) v

type evm_graph = (int * intermediate_op list * bool * int option) list

let stack_needed op = match op with
| `LOG(n) -> n + 2
| `DUP(n) -> n
| `SWAP(n) -> n + 1
| `CALL | `CALLCODE -> 7
| `DELEGATECALL | `STATICCALL -> 6
| `EXTCODECOPY -> 4
| `CODECOPY | `CALLDATACOPY | `RETURNDATACOPY | `ADDMOD | `MULMOD | `CREATE -> 3
| `RETURN | `REVERT | `SSTORE | `MSTORE | `MSTORE8 | `ADD | `MUL | `SUB | `DIV | `EXP | `MOD | `BYTE | `SIGNEXTEND
| `TWOS | `AND | `OR | `XOR | `LT | `GT | `EQ | `SHA3 -> 2
| `SELFDESTRUCT | `JUMPI(_) | `MLOAD | `ISZERO | `NOT | `BLOCKHASH | `CALLDATALOAD | `BALANCE | `EXTCODESIZE 
| `SLOAD | `POP -> 1
| `INVALID | `STOP | `JUMPDEST(_) | `JUMP(_) | `PC | `GAS | `GASPRICE | `GASLIMIT | `COINBASE | `TIMESTAMP
| `NUMBER | `DIFFICULTY  | `ADDRESS | `ORIGIN | `CALLER | `CALLVALUE | `MSIZE | `CODESIZE | `CALLDATASIZE 
| `RETURNDATASIZE | `PUSH(_) -> 0

let compute_cfg (intermediate: intermediate_op list) : evm_graph =
  let output = ref [] in
  let rev_component = ref [] in
  let delta = ref 0 in
  let max_needed = ref 0 in
  List.iter (fun op ->
    let old_component = !rev_component in
    rev_component := op :: !rev_component;
    let total_needed = stack_needed op in
    let diff_needed = total_needed - !delta in
    max_needed := max !max_needed diff_needed;
    (match op with
    | `LOG(n) -> delta := !delta - 2 - n
    | `CALL | `CALLCODE -> delta := !delta - 6
    | `DELEGATECALL | `STATICCALL -> delta := !delta - 5
    | `EXTCODECOPY -> delta := !delta - 4
    | `CODECOPY | `CALLDATACOPY | `RETURNDATACOPY -> delta := !delta - 3
    | `SSTORE | `ADDMOD | `MULMOD | `CREATE | `MSTORE | `MSTORE8 -> delta := !delta - 2
    | `POP | `ADD | `MUL | `SUB | `DIV | `EXP | `MOD | `BYTE | `SIGNEXTEND | `TWOS
    | `AND | `OR | `XOR | `LT | `GT | `EQ | `SHA3  -> delta := !delta - 1
    | `SWAP(_) | `MLOAD | `ISZERO | `NOT | `BLOCKHASH | `CALLDATALOAD | `BALANCE
    | `EXTCODESIZE | `SLOAD -> ()
    | `DUP(_) | `PUSH(_) | `PC | `GAS | `GASPRICE | `GASLIMIT | `COINBASE | `TIMESTAMP | `NUMBER | `DIFFICULTY
    | `ADDRESS | `ORIGIN | `CALLER | `CALLVALUE | `MSIZE | `CODESIZE | `CALLDATASIZE 
    | `RETURNDATASIZE -> delta := !delta + 1
    | `JUMPDEST pc -> 
      let component = List.rev old_component in
      rev_component := [`JUMPDEST pc];
      output := (!max_needed,component,Fallthrough) :: !output;
      max_needed := 0;
      delta := 0
    | `JUMP(pc) ->
      let component = List.rev !rev_component in
      rev_component := [];
      output := (!max_needed,component,Jump(pc)) :: !output;
      max_needed := 0;
      delta := 0
    | `JUMPI(pc) ->
      let component = List.rev !rev_component in
      rev_component := [];
      output := (!max_needed,component,Jumpi(pc)) :: !output;
      max_needed := 0;
      delta := 0
    | `STOP | `INVALID | `SELFDESTRUCT | `RETURN | `REVERT ->
      let component = List.rev !rev_component in
      rev_component := [];
      output := (!max_needed,component,Halt) :: !output;
      max_needed := 0;
      delta := 0
    | `LOCALRETURN ->
      let component = List.rev !rev_component in
      rev_component := [];
      output := (!max_needed,component,Return) :: !output;
      max_needed := 0;
      delta := 0
    )) intermediate;
  let component = List.rev !rev_component in
  output := (!max_needed,component,Fallthrough) :: !output;
  List.filter (fun (_,ops,_) -> ops <> []) (List.rev !output)

type iele_graph = (int list * iele_op list * int list * successor) list

let convert_to_registers (cfg : evm_graph) : iele_graph * int =
  let regcount = ref 2 in
  let components = List.map (fun (max_needed,ops,successors) -> 
  let stack = ref [] in
  for i = 1 to max_needed do
    stack := !regcount :: !stack;
    regcount := !regcount + 1
  done;
  let pre_stack = !stack in
  let reg_ops = List.map (fun op ->
  let curr_stack = !stack in
  match op with
  | `POP -> 
    (match curr_stack with
     | [] -> VoidOp(`INVALID,[])
     | _ :: tl -> stack := tl; Nop)
  | `DUP(i) ->
    if List.length curr_stack < i then VoidOp(`INVALID,[])
    else (stack := List.nth curr_stack (i-1) :: curr_stack; Nop)
  | `SWAP(i) ->
    if List.length curr_stack < i+1 then VoidOp(`INVALID,[])
    else (stack := List.nth curr_stack i :: List.tl (set_nth curr_stack i (List.hd curr_stack)); Nop)
  | `PUSH(v) -> 
    let op = LiOp(`LOADPOS,!regcount,v) in
    stack := !regcount :: curr_stack;
    regcount := !regcount + 1;
    op
  | `INVALID | `STOP | `JUMPDEST(_) | `JUMP(_) as op -> VoidOp(op,[]) (* nullary consumer *)
  | `PC | `GAS | `GASPRICE | `GASLIMIT | `COINBASE | `TIMESTAMP | `NUMBER | `DIFFICULTY | `ADDRESS | `ORIGIN
  | `CALLER | `CALLVALUE | `MSIZE | `CODESIZE | `CALLDATASIZE | `RETURNDATASIZE as op-> 
    let op = Op(op,!regcount,[]) in
    stack := !regcount :: curr_stack;
    regcount := !regcount + 1;
    op (* nullary operator *)
  | `MLOAD256 | `ISZERO | `NOT | `BLOCKHASH | `CALLDATALOAD | `BALANCE | `EXTCODESIZE | `SLOAD as op ->
    (match curr_stack with [] -> VoidOp(`INVALID,[])
    | hd :: tl -> let op = Op(op,!regcount,[hd]) in
    stack := !regcount :: tl;
    regcount := !regcount + 1;
    op) (* unary operator *)
  | `SELFDESTRUCT | `JUMPI(_) as op -> 
    (match curr_stack with [] -> VoidOp(`INVALID,[])
    | hd :: tl -> let op = VoidOp(op,[hd]) in
    stack := tl;
    op) (* unary consumer *)
  | `ADD | `MUL | `SUB | `DIV | `EXP | `MOD | `BYTE | `SIGNEXTEND | `TWOS | `AND | `OR | `XOR
  | `LT | `GT | `EQ | `SHA3 | `MLOAD as op->
    (match curr_stack with [] | _ :: [] -> VoidOp(`INVALID,[])
    | r1 :: r2 :: tl -> let op = Op(op,!regcount,[r1;r2]) in
    stack := !regcount :: tl;
    regcount := !regcount + 1;
    op) (* binary operator *)
  | `MSTORE256 | `MSTORE8 | `LOG(0) | `SSTORE as op-> 
    (match curr_stack with [] | _ :: [] -> VoidOp(`INVALID,[])
    | r1 :: r2 :: tl -> let op = VoidOp(op,[r1;r2]) in
    stack := tl;
    op) (* binary consumer *)
  | `ADDMOD | `MULMOD | `CREATE as op ->
    (match curr_stack with [] | _ :: [] | _ :: _ :: [] -> VoidOp(`INVALID,[])
    | r1 :: r2 :: r3 :: tl -> let op = Op(op,!regcount,[r1;r2;r3]) in
    stack := !regcount :: tl;
    regcount := !regcount + 1;
    op) (* ternary operator *)
  | `CODECOPY | `CALLDATACOPY | `RETURNDATACOPY | `MSTORE | `LOG(1) as op ->
    (match curr_stack with [] | _ :: [] | _ :: _ :: [] -> VoidOp(`INVALID,[])
    | r1 :: r2 :: r3 :: tl -> let op = VoidOp(op,[r1;r2;r3]) in
    stack := tl;
    op) (* ternary consumer *)
  | `EXTCODECOPY | `LOG(2) as op ->
    (match curr_stack with [] | _ :: [] | _ :: _ :: [] | _ :: _ :: _ :: [] -> VoidOp(`INVALID,[])
    | r1 :: r2 :: r3 :: r4 :: tl -> let op = VoidOp(op,[r1;r2;r3;r4]) in
    stack := tl;
    op) (* quaternary consumer *)
  | `LOG(3) as op ->
    (match curr_stack with [] | _ :: [] | _ :: _ :: [] | _ :: _ :: _ :: [] | _ :: _ :: _ :: _ :: [] -> VoidOp(`INVALID,[])
    | r1 :: r2 :: r3 :: r4 :: r5 :: tl -> let op = VoidOp(op,[r1;r2;r3;r4;r5]) in
    stack := tl;
    op) (* 5-ary consumer *)
  | `LOG(4) as op ->
    (match curr_stack with [] | _ :: [] | _ :: _ :: [] | _ :: _ :: _ :: [] | _ :: _ :: _ :: _ :: [] | _ :: _ :: _ :: _ :: _ :: [] -> VoidOp(`INVALID,[])
    | r1 :: r2 :: r3 :: r4 :: r5 :: r6 :: tl -> let op = VoidOp(op,[r1;r2;r3;r4;r5;r6]) in
    stack := tl;
    op) (* 6-ary consumer *)
  | `LOG(_) -> failwith "invalid LOG operand"
  | `DELEGATECALL | `STATICCALL as op ->
    (match curr_stack with []|_::[]|_::_::[]|_::_::_::[]|_::_::_::_::[]|_::_::_::_::_::[] -> Op(`INVALID,[])
    | r1 :: r2 :: r3 :: r4 :: r5 :: r6 :: tl -> let op = Op(op,[!regcount;r1;r2;r3;r4;r5;r6]) in
    stack := !regcount :: tl;
    regcount := !regcount + 1;
    op) (* 6-ary operator *)
  | `CALL | `CALLCODE as op ->
    (match curr_stack with []|_::[]|_::_::[]|_::_::_::[]|_::_::_::_::[]|_::_::_::_::_::[]|_::_::_::_::_::_::[] -> Op(`INVALID,[])
    | r1 :: r2 :: r3 :: r4 :: r5 :: r6 :: r7 :: tl -> let op = Op(op,[!regcount;r1;r2;r3;r4;r5;r6;r7]) in
    stack := !regcount :: tl;
    regcount := !regcount + 1;
    op) (* 7-ary operator *)
  | `LOCALRETURN ->
    VoidOp(`LOCALRETURN(List.length curr_stack),curr_stack)
    (* n-ary consumer *)
  ) ops
  in (pre_stack,reg_ops,!stack,successors)) cfg
  in components,!regcount

let is_predecessor pre_idx idx succ jumpdest = 
match succ,jumpdest with
| Fallthrough,_ -> pre_idx + 1 = idx
| Jump pc,Some dest | Call {ret_addr=pc;_},Some dest -> pc = dest
| Jumpi pc,Some dest | Calli {ret_addr=pc;_},Some dest -> pre_idx + 1 = idx || pc = dest
| Jump _,None | Call _,None -> false
| Jumpi _,None | Calli _,None -> pre_idx + 1 = idx
| Halt,_|Return,_ -> false

let get_predecessors  (graph : iele_graph) (idx: int) (ops: iele_op list) : int list =
  let jumpdest = match ops with
  | VoidOp(`JUMPDEST(pc),[]) :: _ -> Some pc
  | _ -> None
  in
  let map = List.mapi (fun pre_idx (_,_,post_stack,succ) -> 
    let is_pred = is_predecessor pre_idx idx succ jumpdest in 
    if is_pred then [pre_idx] else []) graph in
  List.flatten map

let annotate_graph_with_predecessors (graph : iele_graph) : (int * int list * int list * iele_op list * int list * successor) list =
 List.mapi (fun idx (pre_stack,ops,post_stack,succ) -> (idx,get_predecessors graph idx ops,pre_stack,ops,post_stack,succ)) graph

let range i j = 
    let rec aux n acc =
      if n < i then acc else aux (n-1) (n :: acc)
    in aux j []

module IntMap = Map.Make(struct
  type t = int
  let compare = compare
end)

module IntSet = Set.Make(struct
  type t = int
  let compare = compare
end)

let rec get_return_register ops = match ops with
| VoidOp(`LOCALRETURN(_), reg :: _) :: [] -> reg
| _ :: hd :: tl -> get_return_register (hd :: tl)
| _ -> failwith "invalid return block not ending in RETURN"

let rec find_definition ops register = match ops with
| LiOp(_,reg,payload) as op :: _ when reg = register -> Some op
| Op(_,reg,_) as op :: _ when reg = register -> Some op
| _ :: tl -> find_definition tl register
| [] -> None

let index_of l v = 
  let rec index_of_aux l v i = match l with
  | [] -> failwith "index_of"
  | v2 :: _ when v2 = v -> i
  | _ :: tl -> index_of_aux tl v (i + 1)
  in index_of_aux l v 0

let find_calls_for_return (graph_map : (int * int list * int list * iele_op list * int list * successor) IntMap.t) (jumpdest_map : int IntMap.t) (return_block_id: int) : (int * int * int * int * int) IntMap.t =
  let visited = ref IntSet.empty in
  let return_block = IntMap.find return_block_id graph_map in
  let pre_stack,ops,post_stack = match return_block with (_,_,pre_stack,ops,post_stack,_) -> pre_stack,ops,post_stack in
  let regnum = get_return_register ops in
  let definition = find_definition ops regnum in
  let queue = ref [] in
  let callers = ref IntMap.empty in
  let idx = if definition = None then index_of pre_stack regnum else 0 in
  let rec real_call_block block_id =
    let (idx,_,_,_,_,succ) as block = IntMap.find block_id graph_map in
    match succ with
    | Fallthrough -> real_call_block (block_id + 1)
    | Call {ret_block=pc;_} | Calli {ret_block=pc;_} -> real_call_block pc
    | Jump _ | Jumpi _ | Return -> block_id
    | Halt -> failwith "failed to compute call instruction for PUSH of return address"
  in
  let process_definition block_id stack_idx definition delta = 
    if IntSet.mem block_id !visited then () else begin
      visited := IntSet.add block_id !visited;
      let (_,predecessors,pre_stack,_,post_stack,succ) as block = IntMap.find block_id graph_map in
      let raw_block_delta = (List.length post_stack) - (List.length pre_stack) in
      let block_call_delta = match succ with
      | Call{delta=call_delta;_} -> Some (call_delta-1)
      | Calli{delta=0;_} -> Some (-1)
      | Fallthrough | Jump _ | Jumpi _ | Return | Halt -> Some 0
      | Calli _ -> None
      in
      let block_delta = match block_call_delta with Some n -> Some (raw_block_delta + n) | None -> None in
      match definition with
      | Some LiOp(`LOADPOS,reg,pc) when Z.lt pc _65536 ->
        (match delta with None -> failwith "dynamic stack delta for function detected" | Some delta ->
        callers := IntMap.add block_id (reg,Z.to_int pc,real_call_block block_id,delta,return_block_id) !callers)
      | Some _ -> failwith "dynamic jump detected"
      | None ->
        List.iter (fun predecessor_id ->
                   let (_,_,pre_stack,_,post_stack,succ) as predecessor = IntMap.find predecessor_id graph_map in
                   let predecessor_call_delta = match succ with
                   | Call{delta=call_delta;_} -> call_delta-1
                   | Calli{delta=0;_} -> -1
                   | Fallthrough | Jump _ | Jumpi _ | Halt | Return -> 0
                   | Calli _ -> failwith "dynamic stack delta for function detected"
                   in
                   let predecessor_idx,new_delta = 
                     let predecessor_delta = (List.length pre_stack) - (List.length post_stack) in
                     stack_idx + predecessor_delta - predecessor_call_delta, (match delta,block_delta with Some n,Some m -> Some (n + m) | None,_|_,None -> None)
                   in
                   queue := (predecessor_id,stack_idx - predecessor_call_delta,predecessor_idx,new_delta) :: !queue) predecessors
    end
  in
  process_definition return_block_id idx definition (Some 0);
  while !queue <> [] do
    let block_id,post_idx,pre_idx,delta = List.hd !queue in
    queue := List.tl !queue;
    let (_,_,pre_stack,ops,post_stack,_) as block = IntMap.find block_id graph_map in
    let len = List.length post_stack in
    let definition = if post_idx >= len then None else
    let register = List.nth post_stack post_idx in
    find_definition ops register in
    process_definition block_id pre_idx definition delta
  done;
  !callers

let rec headn l n = match n with
| 0 -> []
| _ -> List.hd l :: headn (List.tl l) (n-1)

let rec tailn l n = match n with
| 0 -> []
| _ -> tailn (List.tl l) (n-1)

let convert_to_call_return ((graph,regcount) : iele_graph * int) : iele_graph * int =
  let regcount = ref regcount in
  let jumpdest_map = snd (List.fold_left (fun (idx,map) (_,ops,_,_) ->
      match ops with
      | VoidOp(`JUMPDEST(pc),[]) :: _ -> idx+1,IntMap.add pc idx map
      | _ -> (idx+1,map)
      ) (0,IntMap.empty) graph) in
  let graph_step graph =
    let annotated_graph = annotate_graph_with_predecessors graph in
    let graph_map = List.fold_left (fun map ((idx,_,_,_,_,_) as component) -> (IntMap.add idx component map)) IntMap.empty annotated_graph in
    let return_blocks = IntMap.filter (fun _ (_,_,_,_,_,succ) -> match succ with Return -> true | _ -> false) graph_map in
    let bindings = IntMap.bindings return_blocks in
    let return_block_ids,_ = List.split bindings in
    let call_blocks = List.map (find_calls_for_return graph_map jumpdest_map) return_block_ids in
    let all_call_blocks = List.fold_left (IntMap.union (fun _ _ _ -> failwith "inconsistent caller blocks")) IntMap.empty call_blocks in
    let real_call_blocks = IntMap.fold (fun _ (reg,ret_addr,idx,delta,return_block_id) map -> IntMap.add idx (ret_addr,delta,reg,return_block_id) map) all_call_blocks IntMap.empty in
    let new_graph = List.mapi (fun idx ((pre_stack,ops,post_stack,_) as component) -> 
        if not (IntMap.mem idx real_call_blocks) then component else
        let len = List.length ops in
        let last = List.nth ops (len-1) in
        let ret_addr,delta,reg,return_block_id = IntMap.find idx real_call_blocks in
        let ret_block = try IntMap.find ret_addr jumpdest_map with Not_found -> -1 in
        match last with
        | VoidOp(`JUMP(pc),[]) -> 
          (pre_stack,ops,post_stack,Call{call=pc;ret_addr=ret_addr;ret_block=ret_block;delta=delta;reg=reg;return_block=return_block_id})
        | VoidOp(`JUMPI(pc),[reg]) -> 
          (pre_stack,ops,post_stack,Calli{call=pc;ret_addr=ret_addr;ret_block=ret_block;delta=delta;reg=reg;return_block=return_block_id})
        | VoidOp(`LOCALRETURN(_),reg :: _) ->
          (pre_stack,set_nth ops (len-1) (VoidOp(`JUMP(ret_addr),[])),List.tl post_stack,Jump ret_addr)
        | _ -> failwith "invalid caller block not ending in JUMP"
        ) graph in
    new_graph
  in
  let rec recompute_graph old_graph =
    let new_graph = graph_step old_graph in
    if new_graph = old_graph then new_graph else
    recompute_graph new_graph
  in
  let new_graph = recompute_graph graph in
  let annotated_graph = annotate_graph_with_predecessors new_graph in
  let graph_map = List.fold_left (fun map ((idx,_,_,_,_,_) as component) -> (IntMap.add idx component map)) IntMap.empty annotated_graph in
  let return_blocks = IntMap.filter (fun _ (_,_,_,_,_,succ) -> match succ with Return -> true | _ -> false) graph_map in
  let all_call_registers = IntSet.of_list (List.flatten (List.map (fun (pre_stack,ops,post_stack,succ) ->
      match succ with
      | Call {reg=reg;_} | Calli {reg=reg;_} -> [reg] 
      | Jump _ | Jumpi _ | Halt | Fallthrough | Return -> []
      ) new_graph)) in
  let without_loads = List.mapi (fun idx (pre_stack,ops,post_stack,succ) ->
      let new_ops = List.flatten (List.map (fun op ->
        match op with
        | LiOp(`LOADPOS, reg, _) when IntSet.mem reg all_call_registers -> []
        | _ -> [op]) ops) in
      (pre_stack,new_ops,post_stack,succ)
      ) new_graph in
  let with_calls = List.mapi (fun idx ((pre_stack,ops,post_stack,succ) as component) ->
      match succ with
      | Jump _ | Jumpi _ | Halt | Fallthrough | Return -> component
      | Call {call=call_addr;ret_addr=ret_addr;return_block=return_block;delta=delta;_} | Calli{call=call_addr;ret_addr=ret_addr;return_block=return_block;delta=delta;_} ->
      let len = List.length ops in
      let last = List.nth ops (len-1) in
      let new_ops = set_nth ops (len-1) Nop in
      let call_block = try IntMap.find call_addr jumpdest_map with Not_found -> -1 in
      match last with
      | VoidOp(`JUMP(pc),[]) -> 
        let (call_pre_stack,_,_,_) = List.nth without_loads call_block in
        let (_,_,return_post_stack,_) = List.nth without_loads return_block in
        let nargs = List.length call_pre_stack - 1 in
        let nparams = List.length post_stack in
        let nreturn = List.length return_post_stack - 1 in
        let nnew_args = nargs - nparams in
        let new_args = range !regcount (!regcount + nnew_args - 1) in
        regcount := !regcount + (max 0 nnew_args);
        let extended_post_stack = post_stack @ new_args in
        let new_post_stack = tailn extended_post_stack nargs in
        let call_args = headn extended_post_stack nargs in
        let new_return_args = range !regcount (!regcount + nreturn - 1) in 
        regcount := !regcount + (max 0 nreturn);
        (pre_stack,new_ops @ (CallOp(`LOCALCALL(pc,nargs,nreturn),new_return_args,call_args) :: VoidOp(`JUMP(ret_addr),[]) :: []),new_return_args @ new_post_stack,Jump ret_addr)
      | VoidOp(`JUMPI(pc),[reg]) -> 
        let (call_pre_stack,_,_,_) = List.nth without_loads call_block in
        let (_,_,return_post_stack,_) = List.nth without_loads return_block in
        let nargs = List.length call_pre_stack - 1 in
        let nparams = List.length post_stack in
        let nreturn = List.length return_post_stack - 1 in
        let nnew_args = nargs - nparams in
        let new_args = range !regcount (!regcount + nnew_args - 1) in
        regcount := !regcount + (max 0 nnew_args);
        let extended_post_stack = post_stack @ new_args in
        let new_post_stack = tailn extended_post_stack nargs in
        let call_args = headn extended_post_stack nargs in
        let new_return_args = range !regcount (!regcount + nreturn - 1) in 
        regcount := !regcount + (max 0 nreturn);
        (pre_stack,new_ops @ (CallOp(`LOCALCALLI(pc,nargs,nreturn,ret_addr),new_return_args,reg :: call_args) :: []),new_return_args @ new_post_stack,succ)
      | _ -> failwith "invalid caller block not ending in JUMP"
      ) without_loads in
  let with_returns = List.mapi (fun idx ((pre_stack,ops,post_stack,succ) as component) ->
      if IntMap.mem idx return_blocks then begin
        let len = List.length ops in
        (pre_stack,set_nth ops (len - 1) (VoidOp(`LOCALRETURN(List.length post_stack - 1),List.tl post_stack)),post_stack,succ)
      end else component) with_calls in
  with_returns,!regcount

let replace_registers (find: int -> int) (op: iele_op) : iele_op = match op with
| Nop -> Nop
| CallOp(opcode,ret_regs,call_regs) -> CallOp(opcode,List.map find ret_regs,List.map find call_regs)
| Op(opcode,reg,regs) -> Op(opcode,(find reg),List.map find regs)
| VoidOp(opcode,regs) -> VoidOp(opcode,List.map find regs)
| LiOp(opcode,reg,payload) -> LiOp(opcode,(find reg),payload)

let replace_labels (find: int -> int) (op: iele_op) : iele_op = 
let aux opcode = match opcode with
| `JUMP(lbl) -> `JUMP(find lbl)
| `JUMPI(lbl) -> `JUMPI(find lbl)
| `JUMPDEST(lbl) -> `JUMPDEST(find lbl)
| `LOCALCALL(lbl,a,r) -> `LOCALCALL(find lbl,a,r)
| _ -> opcode
in match op with
| Nop -> Nop
| CallOp(opcode,ret_regs,call_regs) -> CallOp(aux opcode,ret_regs,call_regs)
| Op(opcode,reg,regs) -> Op(aux opcode,reg,regs)
| VoidOp(opcode,regs) -> VoidOp(aux opcode,regs)
| LiOp(opcode,reg,payload) -> LiOp(aux opcode,reg,payload)

let rec ops_contain ops reg = match ops with
| Nop :: tl -> ops_contain tl reg
| Op(_,r,regs) :: tl -> List.mem reg regs || r = reg || ops_contain tl reg
| CallOp(_,ret_regs,call_regs) :: tl -> List.mem reg ret_regs || List.mem reg call_regs || ops_contain tl reg
| VoidOp(_,regs) :: tl -> List.mem reg regs || ops_contain tl reg
| LiOp(_,r,_) :: tl -> r = reg || ops_contain tl reg
| [] -> false

let rec discover_phi phi_web pre_stack ops post_stack incoming_edge = match pre_stack,incoming_edge with
  | (phi :: phis), (item :: items) -> IeleUtil.UnionFind.union phi_web phi item; discover_phi phi_web phis ops post_stack items
  | [], _ -> ()
  | _::_ as remaining, [] -> 
    let contains = List.map (ops_contain ops) remaining in
    let contains_any = List.fold_left (||) false contains in
    if contains_any then failwith "found a predecessor basic block where registers cannot be inferred"

let resolve_phi ((graph,regcount) : iele_graph * int) : iele_op list list =
  let annotated_graph = annotate_graph_with_predecessors graph in
  let phi_web = IeleUtil.UnionFind.create regcount in
  let preprocessed_graph = List.map (fun (_,predecessors,pre_stack,ops,post_stack,_) ->
    let incoming_edges = List.map (fun predecessor_id -> 
        let (_,_,_,_,post_stack,_) = List.nth annotated_graph predecessor_id in
        post_stack) predecessors in
    let is_target = match ops with
    | VoidOp(`JUMPDEST(_),_) :: _ -> true
    | _ -> false
    in
    match incoming_edges, pre_stack, is_target with
    | [], _::_, false -> [VoidOp(`INVALID,[])]
    | _ -> List.iter (discover_phi phi_web pre_stack ops post_stack) incoming_edges; ops) annotated_graph in
  List.map (fun ops -> List.map (replace_registers (IeleUtil.UnionFind.find phi_web)) ops) preprocessed_graph

let alloc_registers (ops: iele_op list) : iele_op list = 
  let regs = Hashtbl.create 32 in
  let lbls = Hashtbl.create 32 in
  Hashtbl.add regs 0 0;
  Hashtbl.add regs 1 1;
  let regcount = ref 2 in
  let lblcount = ref 0 in
  let reg_ops = List.map (replace_registers (fun reg -> try Hashtbl.find regs reg with Not_found -> let new_reg = !regcount in Hashtbl.add regs reg new_reg; regcount := new_reg + 1; new_reg)) ops in
  let lbl_ops = List.map (replace_labels (fun lbl -> try Hashtbl.find lbls lbl with Not_found -> let new_lbl = !lblcount in Hashtbl.add lbls lbl new_lbl; lblcount := new_lbl + 1; new_lbl)) reg_ops in
  let regbits = ref 0 in
  regcount := !regcount - 1;
  while !regcount > 0 do
    regbits := !regbits + 1;
    regcount := !regcount asr 1
  done;
  VoidOp(`REGISTERS !regbits,[]) :: lbl_ops

let max_val = Z.sub (Z.shift_left Z.one 255) Z.one

let rec postprocess_iele iele = match iele with
| Nop :: tl -> postprocess_iele tl
| Op(`BYTE, [reg;byte;v]) :: tl -> LiOp(`LOADPOS, -2, _31) :: Op(`SUB, [byte; -2; byte]) :: Op(`BYTE, [reg;byte;v]) :: postprocess_iele tl
| Op(`MSTORE, regs) :: tl -> Op(`MSTORE256, regs) :: postprocess_iele tl
| Op(`MLOAD, regs) :: tl -> Op(`MLOAD256, regs) :: postprocess_iele tl
| Op(`CALLDATALOAD, [reg;datastart]) :: tl -> LiOp(`LOADPOS, -1, _32) :: Op(`CALLDATALOAD, [reg;datastart; -1]) :: postprocess_iele tl
| Op(`EXP, [reg;v1;v2]) :: tl when compatibility -> LiOp(`LOADPOS, -3, pow256) :: Op(`EXPMOD, [reg;v1;v2;-3]) :: postprocess_iele tl
| LiOp(`LOADPOS, reg, z) :: tl when compatibility && Z.gt z max_val -> LiOp(`LOADNEG, reg, Z.signed_extract z 0 256) :: postprocess_iele tl
| hd :: tl -> hd :: postprocess_iele tl
| [] -> []

let evm_to_iele (evm:evm_op list) : iele_op list =
  let preprocessed = preprocess_evm evm in
  let cfg = compute_cfg preprocessed in
  let with_registers = convert_to_registers cfg in
  let with_call = convert_to_call_return with_registers in
  let resolved = resolve_phi with_call in
  let flattened = List.flatten resolved in
  let postprocessed = postprocess_iele flattened in
  match postprocessed with
  | [] -> []
  | _::_ -> alloc_registers postprocessed
