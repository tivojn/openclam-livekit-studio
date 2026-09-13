// CSP-safe equivalents of Emscripten's generated binding dispatchers.
// No string compilation; the WASM codec and conversion/destructor rules stay
// identical. Keep this patch bounded and fail closed after upstream changes.
export const craftInvoker = `function craftInvokerFunction(humanName,argTypes,classType,cppInvokerFunc,cppTargetFunc,isAsync){
  var argCount=argTypes.length;
  if(argCount<2)throwBindingError('argTypes array size mismatch');
  var method=argTypes[1]!==null&&classType!==null;
  var stack=usesDestructorStack(argTypes),returns=argTypes[0].name!=='void';
  return createNamedFunction(humanName,function(...args){
    if(args.length!==argCount-2)throwBindingError('function '+humanName+' called with '+args.length+' arguments, expected '+(argCount-2));
    var destructors=stack?[]:null,wire=[cppTargetFunc],converted=[];
    if(method){var value=argTypes[1].toWireType(destructors,this);wire.push(value);converted.push([argTypes[1],value]);}
    for(var i=0;i<args.length;i++){var value=argTypes[i+2].toWireType(destructors,args[i]);wire.push(value);converted.push([argTypes[i+2],value]);}
    var rv=cppInvokerFunc(...wire);
    if(stack)runDestructors(destructors);
    else for(var entry of converted)if(entry[0].destructorFunction!==null)entry[0].destructorFunction(entry[1]);
    if(returns)return argTypes[0].fromWireType(rv);
  });
}`;
export const methodCaller = `var __emval_get_method_caller=(argCount,argTypes,kind)=>{
  var types=emval_lookupTypes(argCount,argTypes),retType=types.shift();
  var invoker=function(obj,func,destructorsRef,args){
    var offset=0,values=[];
    for(var type of types){values.push(type.readValueFromPointer(args+offset));offset+=type.argPackAdvance;}
    var rv=kind===1?Reflect.construct(func,values):func.apply(obj,values);
    if(!retType.isVoid)return emval_returnValue(retType,destructorsRef,rv);
  };
  return emval_addMethodCaller(createNamedFunction('methodCaller',invoker));
};`;
export function cspSafeBasis(source){
  const a=source.indexOf('function craftInvokerFunction('),b=source.indexOf('var __embind_register_class_constructor=',a);
  const c=source.indexOf('var __emval_get_method_caller='),d=source.indexOf('var __emval_get_module_property=',c);
  if([a,b,c,d].some(i=>i<0)||!(a<b&&b<c&&c<d))throw Error('Basis binding glue changed; review the CSP adaptation.');
  const result=source.slice(0,a)+craftInvoker+source.slice(b,c)+methodCaller+source.slice(d);
  if(/newFunc\(Function|new Function\(/.test(result))throw Error('Unexpected dynamic Basis binding remains');
  return '// Modified by OpenClam: static CSP-safe Embind dispatchers; codec/WASM unchanged.\n'+result;
}
