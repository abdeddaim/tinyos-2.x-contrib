/**
 * @author Leon Evers
 */


includes SensorScheme;

module CarPrimM {
  provides interface SSPrimitive;
  uses interface SSRuntime;
}

implementation {

  command ss_val_t SSPrimitive.eval(uint8_t prim) {
    return C_car(arg1);
  };

}