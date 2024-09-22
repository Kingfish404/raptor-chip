
CXXFLAGS += $(shell llvm-config --cxxflags) -fPIE
LDFLAGS += $(shell llvm-config --libs) -L $(shell llvm-config --libdir)
